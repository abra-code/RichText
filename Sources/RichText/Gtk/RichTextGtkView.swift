// Sources/RichText/Gtk/RichTextGtkView.swift
//
// The Linux view: a whole document in ONE read-only GtkTextView, so it is selectable and copyable as a single
// unit, as the Apple RichText view is. A GTK program places `widget` in its widget tree; the view keeps the
// widget alive (one reference of its own) as long as the object lives.
// Pad its sides with the widget's margins (gtk_widget_set_margin_start and _end): the text view's left and right
// margins are the defaults its document's paragraphs replace with their indents. Its top and bottom margins
// (gtk_text_view_set_top_margin, _bottom_margin) are free to use and scroll with the text.
//
// Links open on a click (not on a drag that selects text) through GtkUriLauncher, the system's handler for the
// URL, as the Apple text views open theirs; the pointer is a hand over a link. Code cards, quote bars and the table
// grid are painted behind the text (RichTextGtkDecorations.swift). Images load through
// AsyncImageCache into widgets at their places in the text (RichTextGtkImageSlot), as remoteImages allows.
// Colors follow the GTK style: whatever changes it, a theme, a light/dark switch from GtkSettings or from
// libadwaita, the view recolors the text in place (RichTextGtkDecoratedTextView's css_changed).

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import CRichTextGtk

@MainActor
public final class RichTextGtkView {
    /// The GtkTextView (a `GtkWidget *`).
    public let widget: OpaquePointer

    /// The document shown. Setting it rebuilds the text.
    public var document: RichTextDocument {
        didSet {
            rebuild()
        }
    }

    /// The metrics the document is laid out with. Setting it rebuilds the text.
    /// Whether remote (http, https) images load: automatically, on a click on their placeholder, or never.
    /// Pass it to init so it holds from the first load; changing it later applies to the images not loaded
    /// yet (a load already started goes on).
    public var remoteImages: RichTextRemoteImages = .automatic {
        didSet {
            for slot in imageSlots {
                slot.start(policy: remoteImages)
            }
        }
    }

    public var theme: RichTextTheme {
        didSet {
            rebuild()
        }
    }

    /// Opens a clicked link. The default hands the URL to the system (GtkUriLauncher) with the view's window
    /// as the parent; a host or a test may replace it.
    public var openLink: @MainActor (URL, RichTextGtkView) -> Void = { url, view in
        let launcher = gtk_uri_launcher_new(url.absoluteString)!
        let root = gtk_widget_get_root(view.widgetPointer).map { UnsafeMutableRawPointer($0).assumingMemoryBound(to: GtkWindow.self) }
        gtk_uri_launcher_launch(launcher, root, nil, nil, nil)
        g_object_unref(UnsafeMutableRawPointer(launcher))
    }

    private let textView: UnsafeMutablePointer<GtkTextView>
    private(set) var builder: RichTextGtkBuilder?
    private(set) var links: [RichTextGtkLink] = []
    private(set) var imageSlots: [RichTextGtkImageSlot] = []
    private var layoutRedrawPending = false
    private var layoutRedraws = 0              // for the shown document: a bound, should a line never get a height
    private var settlePending = false
    private var settledSizes: Set<SettledSize> = []   // the sizes a new layout has been asked for, once each
    /// The find controller bound to this view (RichTextGtkFindController.bind(view:)), told when the text changes.
    weak var findController: RichTextGtkFindController?

    /// The GtkTextView, for the decorations' painting (RichTextGtkDecorations.swift).
    var textViewPointer: UnsafeMutablePointer<GtkTextView> {
        textView
    }

    private var widgetPointer: UnsafeMutablePointer<GtkWidget> {
        UnsafeMutableRawPointer(textView).assumingMemoryBound(to: GtkWidget.self)
    }

    public init(document: RichTextDocument, theme: RichTextTheme = .default,
                remoteImages: RichTextRemoteImages = .automatic) {
        self.document = document
        self.theme = theme
        self.remoteImages = remoteImages
        let made = RichTextGtkDecoratedTextView.make()
        g_object_ref_sink(UnsafeMutableRawPointer(made))
        widget = OpaquePointer(made)
        textView = UnsafeMutableRawPointer(made).assumingMemoryBound(to: GtkTextView.self)
        gtk_text_view_set_editable(textView, 0)
        gtk_text_view_set_cursor_visible(textView, 0)
        gtk_text_view_set_wrap_mode(textView, GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_accepts_tab(textView, 0)
        rebuild()
        openLinksOnClick()
        RichTextGtkDecoratedTextView.paint(textView, by: self)
    }

    /// `baseURL` is the document's own location, for Markdown read from a file or a web page: relative image
    /// paths (`img/a.png`) resolve against it (see `RichTextDocument.resolvingImageURLs(against:)`). Without
    /// it they cannot load.
    public convenience init(markdown: String, baseURL: URL? = nil, theme: RichTextTheme = .default,
                            remoteImages: RichTextRemoteImages = .automatic) {
        self.init(document: Self.parse(markdown, baseURL: baseURL), theme: theme, remoteImages: remoteImages)
    }

    /// Shows `markdown`, parsed, with relative image paths resolved against `baseURL` as in `init(markdown:)`.
    public func setMarkdown(_ markdown: String, baseURL: URL? = nil) {
        document = Self.parse(markdown, baseURL: baseURL)
    }

    private static func parse(_ markdown: String, baseURL: URL?) -> RichTextDocument {
        let document = RichTextDocument(markdown: markdown)
        return baseURL.map { document.resolvingImageURLs(against: $0) } ?? document
    }

    /// Reads the colors again from the GTK style and recolors the text in place (selection and scroll stay). The
    /// view does this itself whenever its style changes; a host has no need to.
    public func refreshColors() {
        builder?.recolor(currentPalette())
        // The decorations are painted in the palette's colors, not held by tags.
        gtk_widget_queue_draw(widgetPointer)
    }

    /// The width the document takes with no line wrapped, in pixels (the widget's natural width): the widest of
    /// its paragraphs, code lines and tables, and of its images, which are widgets of their own.
    var naturalWidth: Int32 {
        // GtkTextView lays its text out one pixel narrower than itself (room for the cursor), and Pango's pixel widths
        // are rounded to the nearest: without these two a line this wide would wrap.
        var width = Int32((builder?.naturalWidth ?? 0).rounded(.up)) + 2
        for slot in imageSlots {
            var natural: Int32 = 0
            gtk_widget_measure(slot.widget, GTK_ORIENTATION_HORIZONTAL, -1, nil, &natural, nil, nil)
            width = max(width, natural)
        }
        return width
    }

    /// The widget's style changed, which happens for many reasons (focus, pointer): only a new text color means
    /// new colors, since the palette comes from it.
    func styleChanged() {
        guard let builder, !sameColor(currentForeground(), builder.palette.foreground) else {
            return
        }
        refreshColors()
    }

    private func currentForeground() -> GdkRGBA {
        var foreground = GdkRGBA()
        gtk_widget_get_color(widgetPointer, &foreground)
        return foreground
    }

    private func sameColor(_ a: GdkRGBA, _ b: GdkRGBA) -> Bool {
        a.red == b.red && a.green == b.green && a.blue == b.blue && a.alpha == b.alpha
    }

    /// The link at a character offset of the text, if any.
    func link(atOffset offset: Int) -> URL? {
        links.first { $0.range.contains(offset) }?.url
    }

    // A new buffer each time, so the tags of the old document go with it.
    private func rebuild() {
        let buffer = gtk_text_buffer_new(nil)!
        defer {
            g_object_unref(UnsafeMutableRawPointer(buffer))
        }
        let pango = gtk_widget_get_pango_context(widgetPointer)!
        let made = RichTextGtkBuilder(buffer: buffer, theme: theme, palette: currentPalette(), pango: pango)
        made.build(document)
        builder = made
        links = made.links
        gtk_text_view_set_buffer(textView, buffer)
        // Each image's widget at its anchor; the slots load (or hold) their images.
        imageSlots = made.images.map { image in
            let slot = RichTextGtkImageSlot(alt: image.alt, url: image.url)
            gtk_text_view_add_child_at_anchor(textView, slot.widget, image.anchor)
            return slot
        }
        for slot in imageSlots {
            slot.start(policy: remoteImages)
        }
        layoutRedraws = 0
        settledSizes = []
        settleAfterLayout()
        findController?.textChanged()
    }

    private func currentPalette() -> RichTextGtkPalette {
        RichTextGtkPalette(foreground: currentForeground())
    }

    // MARK: - Redraw after layout

    // A redraw once GTK has laid the text out (an idle below its layout work's priority), for decorations that were
    // painted while lines still had no height. One at a time, and at most 20 for a document.
    func redrawAfterLayout() {
        guard !layoutRedrawPending, layoutRedraws < 20 else {
            return
        }
        layoutRedrawPending = true
        layoutRedraws += 1
        afterLayout { view in
            view.layoutRedrawPending = false
            gtk_widget_queue_draw(view.widgetPointer)
        }
    }

    // Runs `work` once GTK has laid the text out: an idle below its layout work's priority.
    private func afterLayout(_ work: @escaping @MainActor (RichTextGtkView) -> Void) {
        let box = Unmanaged.passRetained(LayoutWork(self, work)).toOpaque()
        g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, { data in
            guard let data else {
                return 0
            }
            nonisolated(unsafe) let box = Unmanaged<LayoutWork>.fromOpaque(data).takeUnretainedValue()
            MainActor.assumeIsolated {
                if let view = box.view {
                    box.work(view)
                }
            }
            return 0
        }, box, { data in
            if let data {
                Unmanaged<LayoutWork>.fromOpaque(data).release()
            }
        })
    }

    private final class LayoutWork {
        weak var view: RichTextGtkView?
        let work: @MainActor (RichTextGtkView) -> Void
        init(_ view: RichTextGtkView, _ work: @escaping @MainActor (RichTextGtkView) -> Void) {
            self.view = view
            self.work = work
        }
    }

    // MARK: - Size

    private struct SettledSize: Hashable {
        let width: Int32
        let height: Int32
    }

    /// After an allocation or a new text: GTK lays the text out in the background, and it does not always ask
    /// for a new size when that gives the view another height (a one-line document measured before it had a
    /// layout stays at height 0). So once the layout is done, ask, unless the view has that height already.
    func settleAfterLayout() {
        guard !settlePending else {
            return
        }
        settlePending = true
        afterLayout { view in
            view.settlePending = false
            view.settle()
        }
    }

    private func settle() {
        // A scrolled window scrolls the text, which is taller than the view on purpose.
        if let parent = gtk_widget_get_parent(widgetPointer),
           g_type_check_instance_is_a(UnsafeMutableRawPointer(parent).assumingMemoryBound(to: GTypeInstance.self),
                                      gtk_scrolled_window_get_type()) != 0 {
            return
        }
        let height = RichTextGtkDecoratedTextView.layoutHeight(of: widgetPointer)
        // The view has its height: nothing is pending, and a later change is a new one, at a size seen before or not
        // (a window narrowed and widened back). This stops the asking below as well, which goes on only while no
        // size is reached.
        guard height != gtk_widget_get_height(widgetPointer) else {
            settledSizes = []
            return
        }
        // Each size once: a parent may hold the view at another height for good (a fixed frame), and heights can
        // alternate with a scroll bar that comes and goes.
        guard settledSizes.insert(SettledSize(width: gtk_widget_get_width(widgetPointer), height: height)).inserted else {
            return
        }
        gtk_widget_queue_resize(widgetPointer)
    }

    // MARK: - Find

    /// The text as shown, with U+FFFC where an image is: the text a find controller searches, in the same
    /// character offsets as the buffer.
    var text: String {
        let buffer = gtk_text_view_get_buffer(textView)!
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        guard let slice = gtk_text_buffer_get_slice(buffer, &start, &end, 1) else {
            return ""
        }
        defer {
            g_free(slice)
        }
        return String(cString: slice)
    }

    // Paints every match, the current one in its own color, and scrolls the current one into view. The tags are
    // made after the document's, so they draw over code and header backgrounds.
    func paintFindHighlights(_ ranges: [Range<Int>], current: Int?) {
        let buffer = gtk_text_view_get_buffer(textView)!
        let match = findTag(in: buffer, name: "richtext-find-match",
                            color: GdkRGBA(red: 1, green: 0.85, blue: 0, alpha: 0.35))
        let currentTag = findTag(in: buffer, name: "richtext-find-current",
                                 color: GdkRGBA(red: 1, green: 0.6, blue: 0, alpha: 0.55))
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        gtk_text_buffer_remove_tag(buffer, match, &start, &end)
        gtk_text_buffer_remove_tag(buffer, currentTag, &start, &end)
        for (index, range) in ranges.enumerated() {
            gtk_text_buffer_get_iter_at_offset(buffer, &start, Int32(range.lowerBound))
            gtk_text_buffer_get_iter_at_offset(buffer, &end, Int32(range.upperBound))
            gtk_text_buffer_apply_tag(buffer, index == current ? currentTag : match, &start, &end)
            if index == current {
                // Through a mark: scrolling to an iter uses line heights not yet computed for a new buffer.
                let mark = gtk_text_buffer_get_mark(buffer, "richtext-find-current")
                    ?? gtk_text_buffer_create_mark(buffer, "richtext-find-current", &start, 1)!
                gtk_text_buffer_move_mark(buffer, mark, &start)
                gtk_text_view_scroll_to_mark(textView, mark, 0.1, 0, 0, 0)
            }
        }
    }

    // The buffer's find tag by name, made on first use (each rebuild makes a new buffer).
    private func findTag(in buffer: UnsafeMutablePointer<GtkTextBuffer>, name: String, color: GdkRGBA)
        -> UnsafeMutablePointer<GtkTextTag> {
        let table = gtk_text_buffer_get_tag_table(buffer)!
        if let existing = gtk_text_tag_table_lookup(table, name) {
            return existing
        }
        let tag = gtk_text_tag_new(name)!
        RichTextGtkBuilder.set(tag, "background-rgba", .rgba(color))
        gtk_text_tag_table_add(table, tag)
        g_object_unref(UnsafeMutableRawPointer(tag))
        return tag
    }

    // MARK: - Links

    private func openLinksOnClick() {
        let click = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(click, guint(GDK_BUTTON_PRIMARY))
        RichTextGtkSignals.onClickReleased(UnsafeMutableRawPointer(click)) { [weak self] x, y in
            self?.clickReleased(x, y)
        }
        gtk_widget_add_controller(widgetPointer, click)

        let motion = gtk_event_controller_motion_new()!
        // Set only when the pointer moves onto or off a link: each set makes a new cursor.
        var overLink = false
        RichTextGtkSignals.onMotion(UnsafeMutableRawPointer(motion)) { [weak self] x, y in
            guard let self else {
                return
            }
            let onLink = link(atPoint: x, y) != nil
            if onLink != overLink {
                overLink = onLink
                gtk_widget_set_cursor_from_name(widgetPointer, onLink ? "pointer" : "text")
            }
        }
        gtk_widget_add_controller(widgetPointer, motion)
    }

    // A click released at x, y opens the link there, unless it selected text (a drag ending on a link).
    private func clickReleased(_ x: Double, _ y: Double) {
        var start = GtkTextIter()
        var end = GtkTextIter()
        let buffer = gtk_text_view_get_buffer(textView)!
        guard gtk_text_buffer_get_selection_bounds(buffer, &start, &end) == 0, let url = link(atPoint: x, y) else {
            return
        }
        openLink(url, self)
    }

    // The link under a point in the view's own coordinates: the character under it, not one past a line's end.
    private func link(atPoint x: Double, _ y: Double) -> URL? {
        var bufferX: Int32 = 0
        var bufferY: Int32 = 0
        gtk_text_view_window_to_buffer_coords(textView, GTK_TEXT_WINDOW_WIDGET, Int32(x), Int32(y), &bufferX, &bufferY)
        var position = GtkTextIter()
        var trailing: Int32 = 0
        guard gtk_text_view_get_iter_at_position(textView, &position, &trailing, bufferX, bufferY) != 0 else {
            return nil
        }
        return link(atOffset: Int(gtk_text_iter_get_offset(&position)))
    }

    isolated deinit {
        g_object_unref(UnsafeMutableRawPointer(widget))
    }
}
