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
// URL, as the Apple text views open theirs; the pointer is a hand over a link. Images load through
// AsyncImageCache into widgets at their places in the text (RichTextGtkImageSlot), as remoteImages allows.
// Colors follow the GTK style: a plain GTK program's light/dark switch (GtkSettings) recolors the text in
// place, and a host whose style changes another way (libadwaita's AdwStyleManager) calls refreshColors().

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
    private var settings: OpaquePointer?          // the GtkSettings the handlers below are connected to
    private var settingsHandlers: [gulong] = []
    private(set) var links: [RichTextGtkLink] = []
    private(set) var imageSlots: [RichTextGtkImageSlot] = []
    /// The find controller bound to this view (RichTextGtkFindController.bind(view:)), told when the text changes.
    weak var findController: RichTextGtkFindController?

    private var widgetPointer: UnsafeMutablePointer<GtkWidget> {
        UnsafeMutableRawPointer(textView).assumingMemoryBound(to: GtkWidget.self)
    }

    public init(document: RichTextDocument, theme: RichTextTheme = .default,
                remoteImages: RichTextRemoteImages = .automatic) {
        self.document = document
        self.theme = theme
        self.remoteImages = remoteImages
        let made = gtk_text_view_new()!
        g_object_ref_sink(UnsafeMutableRawPointer(made))
        widget = OpaquePointer(made)
        textView = UnsafeMutableRawPointer(made).assumingMemoryBound(to: GtkTextView.self)
        gtk_text_view_set_editable(textView, 0)
        gtk_text_view_set_cursor_visible(textView, 0)
        gtk_text_view_set_wrap_mode(textView, GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_accepts_tab(textView, 0)
        rebuild()
        openLinksOnClick()
        followStyleChanges()
    }

    public convenience init(markdown: String, theme: RichTextTheme = .default,
                            remoteImages: RichTextRemoteImages = .automatic) {
        self.init(document: RichTextDocument(markdown: markdown), theme: theme, remoteImages: remoteImages)
    }

    /// Shows `markdown`, parsed.
    public func setMarkdown(_ markdown: String) {
        document = RichTextDocument(markdown: markdown)
    }

    /// Reads the colors again from the GTK style and recolors the text in place (selection and scroll stay).
    /// Called on GtkSettings' theme changes and when the view is shown; a host whose style changes otherwise
    /// (libadwaita's AdwStyleManager "dark") calls it too.
    public func refreshColors() {
        builder?.recolor(currentPalette())
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
        findController?.textChanged()
    }

    private func currentPalette() -> RichTextGtkPalette {
        var foreground = GdkRGBA()
        gtk_widget_get_color(widgetPointer, &foreground)
        return RichTextGtkPalette(foreground: foreground)
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

    // MARK: - Style

    // GtkSettings' theme properties change when a plain GTK program switches light and dark (GTK 4.20 adds
    // gtk-interface-color-scheme, from the desktop's setting; on older GTK that notification never comes); the
    // colors are read again when the view is shown, too (in its window's style).
    private func followStyleChanges() {
        if let settings = gtk_settings_get_default() {
            self.settings = settings
            let object = UnsafeMutableRawPointer(settings)
            for property in ["gtk-application-prefer-dark-theme", "gtk-theme-name", "gtk-interface-color-scheme"] {
                let id = RichTextGtkSignals.onNotify(object, property) { [weak self] in
                    self?.refreshColors()
                }
                if id != 0 {
                    settingsHandlers.append(id)
                }
            }
        }
        RichTextGtkSignals.on(UnsafeMutableRawPointer(textView), "map") { [weak self] in
            self?.refreshColors()
        }
    }

    isolated deinit {
        // The settings outlive the view: their handlers go now. The widget's own controllers go with it.
        if let settings {
            for id in settingsHandlers {
                g_signal_handler_disconnect(UnsafeMutableRawPointer(settings), id)
            }
        }
        g_object_unref(UnsafeMutableRawPointer(widget))
    }
}
