// Sources/RichText/Gtk/RichTextGtkFind.swift
//
// Find in a document on Linux, the counterpart of Find/RichTextFindController.swift and RichTextFindBar.swift,
// in the same layers: the find engine (RichTextSearch); a controller holding the query, the options, the
// matches and the one the reader is on, which paints them on the view it is bound to; and a bar that edits the
// controller, which the host places (above its scrolled window), as on Apple platforms. A host with a search
// field of its own drives `query` and never shows the bar.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import CRichTextGtk

@MainActor
public final class RichTextGtkFindController {

    public var query: String = "" {
        didSet {
            if query != oldValue {
                recompute()
            }
        }
    }

    public var options: RichTextSearchOptions = .default {
        didSet {
            if options != oldValue {
                recompute()
            }
        }
    }

    /// Whether the bar shows (the bar follows it).
    public private(set) var isPresented = false

    /// The matches, in characters of the bound text, and the one the reader is on.
    public private(set) var ranges: [Range<Int>] = []
    public private(set) var currentIndex: Int?

    /// Runs after any change of matches, current match or presentation (the bar updates from it).
    var onChange: [@MainActor () -> Void] = []
    /// Set by present(), cleared by the bar that puts the focus in its field (again on a repeat Ctrl+F).
    var focusRequested = false

    private var text = ""
    private weak var view: RichTextGtkView?

    public init() {}

    /// Searches `text` (no painting): for a host that shows the matches itself.
    public func bind(text: String) {
        unbindView()
        self.text = text
        recompute()
    }

    /// Searches what `view` shows and paints the matches on it; follows the view when its document changes.
    public func bind(view: RichTextGtkView) {
        if view !== self.view {
            unbindView()
        }
        // One controller paints a view: another bound to it before lets it go.
        if let earlier = view.findController, earlier !== self {
            earlier.unbindView()
        }
        self.view = view
        view.findController = self
        textChanged()
    }

    public func next() {
        step(by: 1)
    }

    public func previous() {
        step(by: -1)
    }

    /// Jump to a specific match.
    public func select(_ index: Int) {
        guard ranges.indices.contains(index) else {
            return
        }
        currentIndex = index
        changed()
    }

    /// Hide the bar and clear the query, so nothing stays painted.
    public func dismiss() {
        isPresented = false
        query = ""
        changed()
    }

    /// Show the bar (its field takes focus).
    public func present() {
        isPresented = true
        focusRequested = true
        changed()
    }

    /// "3 of 12", "No matches", or "" for an empty query; "3 of 500+" at the options' limit; "Invalid
    /// expression" for a regular expression that does not compile.
    public var summary: String {
        if !query.unicodeScalars.contains(where: { !$0.properties.isWhitespace && $0 != "\u{200B}" }) {
            return ""
        }
        if !RichTextSearch.isValidQuery(query, options: options) {
            return "Invalid expression"
        }
        guard let currentIndex, !ranges.isEmpty else {
            return "No matches"
        }
        let capped = options.limit.map { ranges.count >= $0 } ?? false
        return "\(currentIndex + 1) of \(ranges.count)\(capped ? "+" : "")"
    }

    /// The bound view rebuilt its text (a new document or theme): search it again.
    func textChanged() {
        if let view {
            text = view.text
        }
        recompute()
    }

    // The view searched until now keeps no highlights and no longer reports to this controller.
    private func unbindView() {
        guard let view else {
            return
        }
        if view.findController === self {
            view.findController = nil
        }
        view.paintFindHighlights([], current: nil)
        self.view = nil
    }

    private func step(by delta: Int) {
        guard !ranges.isEmpty else {
            return
        }
        let count = ranges.count
        let base = currentIndex ?? (delta > 0 ? -1 : 0)
        currentIndex = ((base + delta) % count + count) % count
        changed()
    }

    // As on Apple platforms: the match the reader was on stays current when it is still found.
    private func recompute() {
        let previous = currentIndex.flatMap { ranges.indices.contains($0) ? ranges[$0] : nil }
        ranges = RichTextSearch.ranges(in: text, query: query, options: options)
        if ranges.isEmpty {
            currentIndex = nil
        } else if let previous, let kept = ranges.firstIndex(of: previous) {
            currentIndex = kept
        } else {
            currentIndex = 0
        }
        changed()
    }

    private func changed() {
        view?.paintFindHighlights(ranges, current: currentIndex)
        for run in onChange {
            run()
        }
    }
}

/// The find bar: a search entry, the count ("3 of 12"), previous and next, and the search options, in a
/// GtkSearchBar (Escape closes it). Place `widget` above the scrolled window that holds the view.
@MainActor
public final class RichTextGtkFindBar {
    /// The GtkSearchBar (a `GtkWidget *`).
    public let widget: OpaquePointer
    public let controller: RichTextGtkFindController

    private let searchBar: OpaquePointer
    private let entry: UnsafeMutablePointer<GtkWidget>
    var entryForTests: UnsafeMutablePointer<GtkWidget>? { entry }
    var countForTests: UnsafeMutablePointer<GtkWidget> { count }
    var stepButtonsEnabledForTests: Bool { gtk_widget_get_sensitive(nextButton) != 0 && gtk_widget_get_sensitive(previousButton) != 0 }
    var optionStatesForTests: [Bool] { checks.map { gtk_check_button_get_active($0.0) != 0 } }
    private let count: UnsafeMutablePointer<GtkWidget>
    private let previousButton: UnsafeMutablePointer<GtkWidget>
    private let nextButton: UnsafeMutablePointer<GtkWidget>
    private var checks: [(UnsafeMutablePointer<GtkCheckButton>, WritableKeyPath<RichTextSearchOptions, Bool>)] = []
    private var updating = false

    public init(_ controller: RichTextGtkFindController, placeholder: String = "Find") {
        self.controller = controller
        let bar = gtk_search_bar_new()!
        g_object_ref_sink(UnsafeMutableRawPointer(bar))
        widget = OpaquePointer(bar)
        searchBar = OpaquePointer(bar)
        entry = gtk_search_entry_new()!
        gtk_search_entry_set_placeholder_text(OpaquePointer(entry), placeholder)
        gtk_widget_set_hexpand(entry, 1)
        count = gtk_label_new(nil)!
        gtk_widget_add_css_class(count, "dim-label")
        gtk_widget_add_css_class(count, "numeric")
        let previous = gtk_button_new_from_icon_name("go-up-symbolic")!
        gtk_widget_set_tooltip_text(previous, "Previous Match")
        let next = gtk_button_new_from_icon_name("go-down-symbolic")!
        previousButton = previous
        nextButton = next
        gtk_widget_set_tooltip_text(next, "Next Match")

        let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
        let rowBox = UnsafeMutableRawPointer(row).assumingMemoryBound(to: GtkBox.self)
        let (optionsButton, checks) = Self.optionsButton(controller)
        self.checks = checks
        for child in [entry, count, previous, next, optionsButton] {
            gtk_box_append(rowBox, child)
        }
        gtk_widget_set_size_request(row, 360, -1)
        gtk_search_bar_set_child(searchBar, row)
        gtk_search_bar_connect_entry(searchBar, OpaquePointer(entry))
        gtk_search_bar_set_show_close_button(searchBar, 1)

        RichTextGtkSignals.on(UnsafeMutableRawPointer(entry), "search-changed") { [weak self] in
            guard let self, !updating else {
                return
            }
            let text = gtk_editable_get_text(OpaquePointer(entry)).map { String(cString: $0) } ?? ""
            self.controller.query = text
        }
        for (signal, run) in [("activate", controller.next), ("next-match", controller.next),
                              ("previous-match", controller.previous)] as [(String, @MainActor () -> Void)] {
            RichTextGtkSignals.on(UnsafeMutableRawPointer(entry), signal) { run() }
        }
        RichTextGtkSignals.on(UnsafeMutableRawPointer(entry), "stop-search") { [weak controller] in
            controller?.dismiss()
        }
        RichTextGtkSignals.on(UnsafeMutableRawPointer(previous), "clicked") { [weak controller] in
            controller?.previous()
        }
        RichTextGtkSignals.on(UnsafeMutableRawPointer(next), "clicked") { [weak controller] in
            controller?.next()
        }
        // The bar's own close button: the controller follows the bar.
        _ = RichTextGtkSignals.onNotify(UnsafeMutableRawPointer(bar), "search-mode-enabled") { [weak self] in
            guard let self, !updating, gtk_search_bar_get_search_mode(searchBar) == 0, self.controller.isPresented else {
                return
            }
            self.controller.dismiss()
        }
        controller.onChange.append { [weak self] in
            self?.update()
        }
        update()
    }

    /// Ctrl+F shows the bar, Ctrl+G and Shift+Ctrl+G step through the matches, while the focus is anywhere
    /// inside `widget` (a container of the bar and the view, or the window).
    public func installShortcuts(on widget: OpaquePointer) {
        let shortcuts = gtk_shortcut_controller_new()!
        gtk_shortcut_controller_set_scope(shortcuts, GTK_SHORTCUT_SCOPE_LOCAL)
        RichTextGtkSignals.addShortcut(to: shortcuts, "<Control>f") { [weak controller] in
            controller?.present()
        }
        RichTextGtkSignals.addShortcut(to: shortcuts, "<Control>g") { [weak controller] in
            controller?.next()
        }
        RichTextGtkSignals.addShortcut(to: shortcuts, "<Shift><Control>g") { [weak controller] in
            controller?.previous()
        }
        gtk_widget_add_controller(UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkWidget.self), shortcuts)
    }

    // The bar shows what the controller holds: presented or not, the query, the count.
    private func update() {
        updating = true
        defer {
            updating = false
        }
        let shown = gtk_search_bar_get_search_mode(searchBar) != 0
        if shown != controller.isPresented {
            gtk_search_bar_set_search_mode(searchBar, controller.isPresented ? 1 : 0)
        }
        if controller.isPresented, controller.focusRequested {
            controller.focusRequested = false
            gtk_widget_grab_focus(entry)
        }
        let current = gtk_editable_get_text(OpaquePointer(entry)).map { String(cString: $0) } ?? ""
        if current != controller.query {
            gtk_editable_set_text(OpaquePointer(entry), controller.query)
        }
        gtk_label_set_text(OpaquePointer(count), controller.summary)
        // As on Apple platforms, stepping is off without matches.
        gtk_widget_set_sensitive(previousButton, controller.ranges.isEmpty ? 0 : 1)
        gtk_widget_set_sensitive(nextButton, controller.ranges.isEmpty ? 0 : 1)
        for (check, path) in checks where (gtk_check_button_get_active(check) != 0) != controller.options[keyPath: path] {
            gtk_check_button_set_active(check, controller.options[keyPath: path] ? 1 : 0)
        }
    }

    // A menu button with a check for each option, and the checks (update() keeps them as the options are).
    private static func optionsButton(_ controller: RichTextGtkFindController)
        -> (UnsafeMutablePointer<GtkWidget>, [(UnsafeMutablePointer<GtkCheckButton>, WritableKeyPath<RichTextSearchOptions, Bool>)]) {
        let button = gtk_menu_button_new()!
        gtk_menu_button_set_icon_name(OpaquePointer(button), "view-more-symbolic")
        gtk_widget_set_tooltip_text(button, "Search Options")
        let list = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4)!
        let options: [(String, WritableKeyPath<RichTextSearchOptions, Bool>)] = [
            ("Match Case", \.caseSensitive),
            ("Match Diacritics", \.diacriticSensitive),
            ("Whole Words", \.wholeWord),
            ("Regular Expression", \.regularExpression),
        ]
        var checks: [(UnsafeMutablePointer<GtkCheckButton>, WritableKeyPath<RichTextSearchOptions, Bool>)] = []
        for (title, path) in options {
            let check = gtk_check_button_new_with_label(title)!
            checks.append((UnsafeMutableRawPointer(check).assumingMemoryBound(to: GtkCheckButton.self), path))
            gtk_check_button_set_active(UnsafeMutableRawPointer(check).assumingMemoryBound(to: GtkCheckButton.self), controller.options[keyPath: path] ? 1 : 0)
            RichTextGtkSignals.on(UnsafeMutableRawPointer(check), "toggled") { [weak controller] in
                controller?.options[keyPath: path] = gtk_check_button_get_active(UnsafeMutableRawPointer(check).assumingMemoryBound(to: GtkCheckButton.self)) != 0
            }
            gtk_box_append(UnsafeMutableRawPointer(list).assumingMemoryBound(to: GtkBox.self), check)
        }
        let popover = gtk_popover_new()!
        gtk_popover_set_child(UnsafeMutableRawPointer(popover).assumingMemoryBound(to: GtkPopover.self), list)
        gtk_menu_button_set_popover(OpaquePointer(button), popover)
        return (button, checks)
    }

    isolated deinit {
        g_object_unref(UnsafeMutableRawPointer(widget))
    }
}
