// Tests/RichTextTests/Gtk/RichTextGtkViewTests.swift
//
// The GTK view. It needs a display (gtk_init), so it is skipped where there is none; in the box, run the tests
// in the GNOME session (XDG_RUNTIME_DIR, WAYLAND_DISPLAY).

import XCTest
import Foundation
import CRichTextGtk
@testable import RichText

@MainActor
final class RichTextGtkViewTests: XCTestCase {

    override func setUp() async throws {
        let ready = await MainActor.run { gtkDisplay() }
        try XCTSkipUnless(ready, "no display")
    }

    func testLinksAreFoundByOffset() {
        let view = RichTextGtkView(markdown: "Read [the docs](https://swift.org) now.")
        XCTAssertEqual(view.link(atOffset: 5), URL(string: "https://swift.org"))
        XCTAssertEqual(view.link(atOffset: 12), URL(string: "https://swift.org"))
        XCTAssertNil(view.link(atOffset: 13), "past the link's end")
        XCTAssertNil(view.link(atOffset: 0))
    }

    func testDocumentChangeReplacesTheLinks() {
        let view = RichTextGtkView(markdown: "[a](https://a.test)")
        view.setMarkdown("plain")
        XCTAssertNil(view.link(atOffset: 0))
        view.theme = RichTextTheme(baseFontSize: 20)
        view.refreshColors()
        XCTAssertNil(view.link(atOffset: 0))
    }

    // A table's long last cell grows to the view's right edge and wraps there, as macOS's tables use the width:
    // its wrapped lines hang at the column, and a narrower view wraps it sooner.
    func testLongLastTableCellWrapsAtTheViewsEdge() throws {
        let long = Array(repeating: "wrapping words", count: 20).joined(separator: " ")
        let window = gtk_window_new()!
        let gtkWindow = UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self)
        gtk_window_set_default_size(gtkWindow, 900, 400)
        let view = RichTextGtkView(markdown: "| Key | Note |\n| --- | --- |\n| a | \(long) |")
        gtk_window_set_child(gtkWindow, UnsafeMutableRawPointer(view.widget).assumingMemoryBound(to: GtkWidget.self))
        gtk_window_present(gtkWindow)
        defer {
            gtk_window_destroy(gtkWindow)
        }
        pump(milliseconds: 500)

        let buffer = try XCTUnwrap(gtk_text_view_get_buffer(view.textViewPointer))
        let text = view.text
        let cellStart = text.unicodeScalars.distance(from: text.unicodeScalars.startIndex,
                                                     to: try XCTUnwrap(text.range(of: "wrapping")).lowerBound)
        let padding = Int32(RichTextTheme.default.cellPadding)
        // Where the cell starts, where its first line ends, its last character, the start of the last line, and
        // the view's right edge.
        func measure() -> (firstX: Int32, firstY: Int32, firstEnd: Int32, lastY: Int32, lastX: Int32, lastLineX: Int32, right: Int32) {
            var iter = GtkTextIter()
            var rect = GdkRectangle()
            gtk_text_buffer_get_iter_at_offset(buffer, &iter, Int32(cellStart))
            gtk_text_view_get_iter_location(view.textViewPointer, &iter, &rect)
            let firstX = rect.x
            let firstY = rect.y
            gtk_text_view_forward_display_line_end(view.textViewPointer, &iter)
            gtk_text_view_get_iter_location(view.textViewPointer, &iter, &rect)
            let firstEnd = rect.x
            gtk_text_buffer_get_iter_at_offset(buffer, &iter, Int32(text.unicodeScalars.count - 1))
            gtk_text_view_get_iter_location(view.textViewPointer, &iter, &rect)
            let last = rect
            gtk_text_view_backward_display_line_start(view.textViewPointer, &iter)
            gtk_text_view_get_iter_location(view.textViewPointer, &iter, &rect)
            var visible = GdkRectangle()
            gtk_text_view_get_visible_rect(view.textViewPointer, &visible)
            return (firstX, firstY, firstEnd, last.y, last.x, rect.x, visible.x + visible.width)
        }

        let wide = measure()
        XCTAssertGreaterThan(wide.firstEnd - wide.firstX, 320, "the column uses the width, not a fixed 320")
        XCTAssertLessThanOrEqual(wide.firstEnd, wide.right - padding, "and wraps inside the view's right edge")
        XCTAssertGreaterThan(wide.lastY, wide.firstY, "onto more lines")
        XCTAssertEqual(wide.lastLineX, wide.firstX, "a wrapped line hangs at the last column")

        gtk_window_set_default_size(gtkWindow, 600, 400)
        pump(milliseconds: 500)
        let narrow = measure()
        XCTAssertLessThan(narrow.right, wide.right)
        XCTAssertLessThanOrEqual(narrow.firstEnd, narrow.right - padding, "a narrower view wraps it sooner")
        XCTAssertGreaterThan(narrow.lastY, wide.lastY)
    }

    // MARK: - Size

    // A view in a plain box, above a label, in a window; returns what `check` says once GTK has settled. The window
    // has a height of its own: one sized by its content is measured again when it opens, which hides a view's own
    // height staying at 0. A `row` is a horizontal box, which gives the view its natural width.
    private func inABox(_ view: RichTextGtkView, windowWidth: Int32 = 400, expands: Bool = false, row: Bool = false,
                        check: (UnsafeMutablePointer<GtkWidget>) -> Void) {
        let window = gtk_window_new()!
        let gtkWindow = UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self)
        gtk_window_set_default_size(gtkWindow, windowWidth, 300)
        let column = gtk_box_new(row ? GTK_ORIENTATION_HORIZONTAL : GTK_ORIENTATION_VERTICAL, 0)!
        let columnBox = UnsafeMutableRawPointer(column).assumingMemoryBound(to: GtkBox.self)
        let widget = UnsafeMutableRawPointer(view.widget).assumingMemoryBound(to: GtkWidget.self)
        gtk_widget_set_hexpand(widget, expands ? 1 : 0)
        gtk_box_append(columnBox, widget)
        gtk_box_append(columnBox, gtk_label_new("below")!)
        gtk_window_set_child(gtkWindow, column)
        gtk_window_present(gtkWindow)
        defer {
            gtk_box_remove(columnBox, widget)
            gtk_window_destroy(gtkWindow)
        }
        pump(milliseconds: 300)
        check(widget)
    }

    // GTK lays a one-line document out without asking for a new size: measured before that, it stayed at height 0.
    func testAShortDocumentIsAllocatedItsHeight() throws {
        inABox(RichTextGtkView(markdown: "Short."), expands: true) { widget in
            XCTAssertGreaterThan(gtk_widget_get_height(widget), 10, "a line of text is not invisible")
            XCTAssertEqual(gtk_widget_get_height(widget), RichTextGtkDecoratedTextView.layoutHeight(of: widget))
        }
    }

    func testANewDocumentIsAllocatedItsHeight() throws {
        let view = RichTextGtkView(markdown: "Short.")
        inABox(view, expands: true) { widget in
            let one = gtk_widget_get_height(widget)
            view.setMarkdown("Short.\n\nTwo.\n\nThree.")
            pump(milliseconds: 300)
            XCTAssertGreaterThan(gtk_widget_get_height(widget), one * 2, "the new text is taller, at the same width")
            XCTAssertEqual(gtk_widget_get_height(widget), RichTextGtkDecoratedTextView.layoutHeight(of: widget))
        }
    }

    // A window narrowed and widened again: each way, GTK wraps a text that fits the view during the allocation,
    // where the new size it asks for is lost. A width seen before needs its own request as much as a new one.
    func testTheHeightFollowsTheWidthBackAndForth() throws {
        let long = String(repeating: "Several words that wrap. ", count: 30)
        inABox(RichTextGtkView(markdown: long), windowWidth: 300) { widget in
            let window = UnsafeMutableRawPointer(gtk_widget_get_root(widget)!).assumingMemoryBound(to: GtkWindow.self)
            for width in [Int32(600), 300, 600, 300, 600] {
                gtk_window_set_default_size(window, width, 300)
                // The compositor's answer takes its time when the session is busy.
                pump { gtk_widget_get_width(widget) == width }
                pump(milliseconds: 300)
                XCTAssertEqual(gtk_widget_get_width(widget), width)
                XCTAssertEqual(gtk_widget_get_height(widget), RichTextGtkDecoratedTextView.layoutHeight(of: widget),
                               "at width \(width)")
            }
        }
    }

    // A parent that keeps the view at another height does not make it ask again and again at idle.
    func testAHeldViewStopsAsking() throws {
        let view = RichTextGtkView(markdown: "Short.")
        gtk_widget_set_vexpand(UnsafeMutableRawPointer(view.widget).assumingMemoryBound(to: GtkWidget.self), 1)
        inABox(view, expands: true) { widget in
            XCTAssertGreaterThan(gtk_widget_get_height(widget), RichTextGtkDecoratedTextView.layoutHeight(of: widget))
            let clock = gtk_widget_get_frame_clock(widget)
            let frames = gdk_frame_clock_get_frame_counter(clock)
            pump(milliseconds: 300)
            // Not 0: a window of another program can take the focus, which redraws this one. A view that keeps
            // asking draws a frame each time, about 18 in this time.
            XCTAssertLessThan(gdk_frame_clock_get_frame_counter(clock) - frames, 6, "nothing changes, so nothing is drawn")
        }
    }

    func testAWrappedDocumentIsAllocatedItsHeight() throws {
        let long = String(repeating: "Several words that wrap. ", count: 30)
        var narrow: Int32 = 0
        inABox(RichTextGtkView(markdown: long), windowWidth: 300) { widget in
            narrow = gtk_widget_get_height(widget)
        }
        var wide: Int32 = 0
        inABox(RichTextGtkView(markdown: long), windowWidth: 900) { widget in
            wide = gtk_widget_get_height(widget)
        }
        XCTAssertGreaterThan(narrow, wide, "wrapping at a narrower width takes more lines")
    }

    func testNaturalWidthIsTheWidestUnwrappedLine() throws {
        func natural(_ markdown: String) -> Int32 {
            let view = RichTextGtkView(markdown: markdown)
            var width: Int32 = 0
            gtk_widget_measure(UnsafeMutableRawPointer(view.widget).assumingMemoryBound(to: GtkWidget.self),
                               GTK_ORIENTATION_HORIZONTAL, -1, nil, &width, nil, nil)
            return width
        }
        let short = natural("Short.")
        XCTAssertGreaterThan(short, 0)
        let long = natural(String(repeating: "word ", count: 40))
        XCTAssertGreaterThan(long, short * 10)
        XCTAssertGreaterThan(natural("# Short."), short, "a heading is drawn larger")
        XCTAssertGreaterThan(natural("Short.\n\n    code line that is long enough to be the widest line here"), short,
                             "a code block's lines count")
        XCTAssertGreaterThan(natural("| a | b |\n|---|---|\n| Short. | Short. |"), short, "so do a table's columns")
        XCTAssertGreaterThan(natural("- Short."), short, "and a list's indent")
    }

    // Given its natural width a document keeps its lines: GtkTextView lays text out a pixel narrower than itself.
    func testANaturalWidthWrapsNoLine() throws {
        let long = "A longer line of ordinary text, with enough words in it to pass the width of the window's minimum."
        for markdown in ["Short.", "A", "Hello world", long, "# A heading", "`code`", "- A list item", "> A quote",
                         "    code line", "| a | b |\n|---|---|\n| one | two |"] {
            let view = RichTextGtkView(markdown: markdown)
            inABox(view, windowWidth: 1200, row: true) { widget in
                XCTAssertEqual(gtk_widget_get_width(widget), view.naturalWidth, markdown)
                let height = RichTextGtkDecoratedTextView.layoutHeight(of: widget)
                gtk_text_view_set_wrap_mode(view.textViewPointer, GTK_WRAP_NONE)
                pump(milliseconds: 100)
                XCTAssertEqual(height, RichTextGtkDecoratedTextView.layoutHeight(of: widget), markdown)
            }
        }
    }

    // The width a heading is drawn at, with the widget's own size and with a theme's.
    func testAHeadingsNaturalWidthIsItsDrawnWidth() throws {
        for theme in [RichTextTheme.default, RichTextTheme(baseFontSize: 20)] {
            let view = RichTextGtkView(markdown: "# A heading of some length", theme: theme)
            inABox(view, windowWidth: 800, row: true) { _ in
                let buffer = gtk_text_view_get_buffer(view.textViewPointer)!
                var end = GtkTextIter()
                gtk_text_buffer_get_end_iter(buffer, &end)
                var rect = GdkRectangle()
                gtk_text_view_get_iter_location(view.textViewPointer, &end, &rect)
                XCTAssertEqual(Double(view.naturalWidth), Double(rect.x), accuracy: 4)
            }
        }
    }

    // A plain GTK program's switch to dark (GtkSettings) recolors the shown text in place.
    func testDarkPreferenceRecolors() throws {
        let settings = try XCTUnwrap(gtk_settings_get_default())
        let window = gtk_window_new()!
        let view = RichTextGtkView(markdown: "[link](https://swift.org)")
        gtk_window_set_child(UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self),
                             UnsafeMutableRawPointer(view.widget).assumingMemoryBound(to: GtkWidget.self))
        gtk_window_present(UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self))
        // Flipped from whatever the session prefers (a settings.ini may already ask for dark), then put back.
        let original = isDark(settings)
        defer {
            setDark(settings, original)
            gtk_window_destroy(UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self))
        }
        pump(milliseconds: 300)
        let before = try XCTUnwrap(view.builder?.palette.link)
        setDark(settings, !original)
        pump(milliseconds: 300)
        let after = try XCTUnwrap(view.builder?.palette.link)
        XCTAssertNotEqual(after, before, "the link color follows the dark style")
    }

    private func isDark(_ settings: OpaquePointer) -> Bool {
        var value = GValue()
        g_value_init(&value, GType(5 << G_TYPE_FUNDAMENTAL_SHIFT))
        g_object_get_property(UnsafeMutableRawPointer(settings).assumingMemoryBound(to: GObject.self),
                              "gtk-application-prefer-dark-theme", &value)
        let dark = g_value_get_boolean(&value) != 0
        g_value_unset(&value)
        return dark
    }

    private func setDark(_ settings: OpaquePointer, _ dark: Bool) {
        var value = GValue()
        g_value_init(&value, GType(5 << G_TYPE_FUNDAMENTAL_SHIFT))
        g_value_set_boolean(&value, dark ? 1 : 0)
        g_object_set_property(UnsafeMutableRawPointer(settings).assumingMemoryBound(to: GObject.self),
                              "gtk-application-prefer-dark-theme", &value)
        g_value_unset(&value)
    }

    private func pump(milliseconds: Int) {
        let end = g_get_monotonic_time() + gint64(milliseconds) * 1000
        while g_get_monotonic_time() < end {
            if g_main_context_iteration(nil, 0) == 0 {
                usleep(1000)
            }
        }
    }

    // MARK: - Images

    func testDataImageLoadsAtItsSizeAndIsCachedForTheNextView() throws {
        let markdown = "![dot](\(try pngDataURL(width: 40, height: 20)))"
        let view = RichTextGtkView(markdown: markdown)
        let slot = try XCTUnwrap(view.imageSlots.first)
        pump(until: { slot.loaded != nil })
        XCTAssertEqual(slot.loaded?.pixelWidth, 40)
        XCTAssertEqual(slot.loaded?.pixelHeight, 20)
        // A second view of the same document shows it at once, from the cache.
        let again = RichTextGtkView(markdown: markdown)
        XCTAssertNotNil(again.imageSlots.first?.loaded)
    }

    func testRemoteImagesFollowThePolicy() throws {
        let view = RichTextGtkView(markdown: "![chart](https://charts.example/c.png)", remoteImages: .never)
        let slot = try XCTUnwrap(view.imageSlots.first)
        XCTAssertEqual(slot.hold, .off)
        XCTAssertEqual(slot.placeholderText, "chart\nNot loaded from charts.example: remote images are off")
        view.remoteImages = .onClick
        XCTAssertEqual(slot.hold, .awaitingClick)
        XCTAssertEqual(slot.placeholderText, "chart\nClick to load from charts.example")
        XCTAssertNil(slot.loaded)
    }

    // A policy change while an image loads must not start a second load and show it twice (a GTK critical).
    func testPolicyChangeDuringALoadShowsTheImageOnce() throws {
        let view = RichTextGtkView(markdown: "![dot](\(try pngDataURL(width: 12, height: 12)))")
        let slot = try XCTUnwrap(view.imageSlots.first)
        view.remoteImages = .onClick
        view.remoteImages = .automatic
        pump(until: { slot.loaded != nil })
        pump(milliseconds: 200)
        XCTAssertEqual(slot.loaded?.pixelWidth, 12)
    }

    // A click approves an image under .onClick only: after its fetch fails, .never holds it again instead of
    // fetching it a second time. (Port 1 on the loopback address refuses at once, so nothing leaves the host.)
    func testClickApprovalDoesNotOutliveNever() throws {
        let view = RichTextGtkView(markdown: "![chart](https://127.0.0.1:1/c.png)", remoteImages: .onClick)
        let slot = try XCTUnwrap(view.imageSlots.first)
        XCTAssertEqual(slot.hold, .awaitingClick)
        slot.placeholderClicked()
        XCTAssertEqual(slot.hold, .none)
        pump(until: { slot.failed })
        XCTAssertTrue(slot.failed)
        view.remoteImages = .never
        XCTAssertEqual(slot.hold, .off)
        XCTAssertEqual(slot.placeholderText, "chart\nNot loaded from 127.0.0.1: remote images are off")
    }

    // A picture beside a Markdown file, by a relative path resolved against the document's location: it loads
    // even with remote images off, since showing it sends nothing anywhere.
    func testLocalImageBesideTheDocumentLoads() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("richtext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("img"), withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }
        let png = try XCTUnwrap(Data(base64Encoded: try pngDataURL(width: 9, height: 7)
            .replacingOccurrences(of: "data:image/png;base64,", with: "")))
        try png.write(to: folder.appendingPathComponent("img/dot.png"))
        let view = RichTextGtkView(markdown: "![dot](img/dot.png)", baseURL: folder.appendingPathComponent("read.md"),
                                   remoteImages: .never)
        let slot = try XCTUnwrap(view.imageSlots.first)
        XCTAssertEqual(slot.hold, .none)
        pump(until: { slot.loaded != nil })
        XCTAssertEqual(slot.loaded?.pixelWidth, 9)
    }

    // Without the document's location a relative path names nothing: unavailable, never guessed.
    func testRelativeImageWithoutABaseIsUnavailable() throws {
        let view = RichTextGtkView(markdown: "![dot](img/dot.png)")
        let slot = try XCTUnwrap(view.imageSlots.first)
        XCTAssertTrue(slot.failed)
        XCTAssertEqual(slot.placeholderText, "dot (unavailable)")
    }

    private func pump(until done: () -> Bool) {
        let end = g_get_monotonic_time() + 5_000_000
        while !done(), g_get_monotonic_time() < end {
            if g_main_context_iteration(nil, 0) == 0 {
                usleep(1000)
            }
        }
    }

    private func pngDataURL(width: Int, height: Int) throws -> String {
        let pixbuf = try XCTUnwrap(gdk_pixbuf_new(GDK_COLORSPACE_RGB, 1, 8, Int32(width), Int32(height)))
        defer {
            g_object_unref(UnsafeMutableRawPointer(pixbuf))
        }
        gdk_pixbuf_fill(pixbuf, 0x3366CCFF)
        var buffer: UnsafeMutablePointer<gchar>?
        var size: gsize = 0
        _ = gdk_pixbuf_save_to_bufferv(pixbuf, &buffer, &size, "png", nil, nil, nil)
        let start = try XCTUnwrap(buffer)
        defer {
            g_free(start)
        }
        return "data:image/png;base64," + Data(bytes: start, count: Int(size)).base64EncodedString()
    }

    // The widget lives while the view does, and the view can go before the widget's window does.
    func testWidgetOutlivesNothingItShouldNot() {
        var view: RichTextGtkView? = RichTextGtkView(markdown: "x")
        let widget = view!.widget
        g_object_ref(UnsafeMutableRawPointer(widget))
        view = nil
        XCTAssertEqual(UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GObject.self).pointee.ref_count, 1)
        g_object_unref(UnsafeMutableRawPointer(widget))
    }
}
