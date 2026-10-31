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

    // Whether GTK could open a display, asked once: after a failed gtk_init_check, GTK aborts on the next one.
    private static var hasDisplay: Bool?

    override func setUp() async throws {
        let ready = await MainActor.run { () -> Bool in
            if let known = Self.hasDisplay {
                return known
            }
            let opened = gtk_init_check() != 0
            Self.hasDisplay = opened
            return opened
        }
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
