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

    func testFileImageIsNeverRead() throws {
        let view = RichTextGtkView(markdown: "![secret](file:///etc/hostname)")
        let slot = try XCTUnwrap(view.imageSlots.first)
        XCTAssertTrue(slot.failed)
        XCTAssertEqual(slot.placeholderText, "secret (unavailable)")
        pump(milliseconds: 100)
        XCTAssertNil(slot.loaded)
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
