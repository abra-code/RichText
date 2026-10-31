// Tests/RichTextTests/Gtk/RichTextGtkFindTests.swift
//
// Find on Linux: the controller's rules (as RichTextFindController's on Apple platforms), the matches painted on
// the bound view, and the bar following the controller. The view and bar tests need a display.

import XCTest
import Foundation
import CRichTextGtk
@testable import RichText

@MainActor
final class RichTextGtkFindTests: XCTestCase {

    // MARK: - Controller (headless)

    func testSummaryAndStepping() {
        let find = RichTextGtkFindController()
        find.bind(text: "one two one three one")
        XCTAssertEqual(find.summary, "")
        find.query = "one"
        XCTAssertEqual(find.ranges, [0..<3, 8..<11, 18..<21])
        XCTAssertEqual(find.summary, "1 of 3")
        find.next()
        find.next()
        XCTAssertEqual(find.summary, "3 of 3")
        find.next()
        XCTAssertEqual(find.currentIndex, 0, "next wraps around")
        find.previous()
        XCTAssertEqual(find.currentIndex, 2, "previous wraps around")
        find.query = "zzz"
        XCTAssertEqual(find.summary, "No matches")
        XCTAssertNil(find.currentIndex)
    }

    func testTheCurrentMatchStaysWhenStillFound() {
        let find = RichTextGtkFindController()
        find.bind(text: "cat Cat cat")
        find.query = "cat"
        find.select(2)
        find.options.caseSensitive = true   // [0, 8]: the third match is now the second
        XCTAssertEqual(find.ranges, [0..<3, 8..<11])
        XCTAssertEqual(find.currentIndex, 1)
    }

    func testInvalidExpressionAndLimit() {
        let find = RichTextGtkFindController()
        find.bind(text: "a a a a")
        find.options = RichTextSearchOptions(regularExpression: true)
        find.query = "("
        XCTAssertEqual(find.summary, "Invalid expression")
        find.options = RichTextSearchOptions(limit: 2)
        find.query = "a"
        XCTAssertEqual(find.summary, "1 of 2+")
        find.dismiss()
        XCTAssertEqual(find.query, "")
        XCTAssertFalse(find.isPresented)
    }

    // MARK: - View and bar (display)

    func testMatchesArePaintedAndFollowTheDocument() throws {
        try XCTSkipUnless(gtkDisplay(), "no display")
        let view = RichTextGtkView(markdown: "Find **me**, then me again.")
        let find = RichTextGtkFindController()
        find.bind(view: view)
        find.query = "me"
        XCTAssertEqual(find.ranges.count, 2)
        XCTAssertEqual(tagName(in: view, at: find.ranges[0].lowerBound), "richtext-find-current")
        XCTAssertEqual(tagName(in: view, at: find.ranges[1].lowerBound), "richtext-find-match")
        XCTAssertNil(tagName(in: view, at: 0))
        find.next()
        XCTAssertEqual(tagName(in: view, at: find.ranges[1].lowerBound), "richtext-find-current")
        // A new document is searched again, and painted.
        view.setMarkdown("me me me")
        XCTAssertEqual(find.ranges.count, 3)
        XCTAssertEqual(tagName(in: view, at: 3), "richtext-find-match")
        // Searching other text leaves the view unpainted and no longer bound.
        find.bind(text: "me")
        XCTAssertNil(tagName(in: view, at: 0), "the view searched before keeps no highlights")
        XCTAssertNil(view.findController)
        find.bind(view: view)
        find.dismiss()
        XCTAssertNil(tagName(in: view, at: 0), "nothing stays painted")
    }

    func testBarFollowsTheController() throws {
        try XCTSkipUnless(gtkDisplay(), "no display")
        let find = RichTextGtkFindController()
        find.bind(text: "alpha beta alpha")
        let bar = RichTextGtkFindBar(find)
        XCTAssertEqual(gtk_search_bar_get_search_mode(bar.widget), 0)
        find.present()
        XCTAssertNotEqual(gtk_search_bar_get_search_mode(bar.widget), 0)
        find.query = "alpha"
        XCTAssertEqual(entryText(bar), "alpha")
        XCTAssertEqual(countText(bar), "1 of 2")
        find.options.caseSensitive = true
        XCTAssertEqual(bar.optionStatesForTests, [true, false, false, false], "the option checks follow the controller")
        find.dismiss()
        XCTAssertEqual(gtk_search_bar_get_search_mode(bar.widget), 0)
        XCTAssertEqual(entryText(bar), "")
    }

    // Closed by the bar itself (its close button, or Escape in the field), the bar opens again on present(). The
    // close button is the case that broke: the bar re-opened inside its own close and then stayed hidden for good.
    // Escape also runs our "stop-search" handler afterwards, which put things right, so it is covered here but
    // was never broken.
    func testBarReopensAfterTheUserClosesIt() throws {
        try XCTSkipUnless(gtkDisplay(), "no display")
        let find = RichTextGtkFindController()
        find.bind(text: "alpha beta alpha")
        let bar = RichTextGtkFindBar(find)
        for close in ["close button", "Escape"] {
            find.present()
            find.query = "alpha"
            pump(milliseconds: 300)
            if close == "close button" {
                gtk_search_bar_set_search_mode(bar.widget, 0)
            } else {
                // Escape in the field emits "stop-search" (g_signal_emit_by_name is variadic, so through emitv).
                var instance = GValue()
                g_value_init(&instance, gtk_search_entry_get_type())
                g_value_set_object(&instance, UnsafeMutableRawPointer(bar.entryForTests!))
                g_signal_emitv(&instance, g_signal_lookup("stop-search", gtk_search_entry_get_type()), 0, nil)
                g_value_unset(&instance)
            }
            pump(milliseconds: 300)
            XCTAssertFalse(find.isPresented, close)
            XCTAssertEqual(gtk_search_bar_get_search_mode(bar.widget), 0, close)
            find.present()
            pump(milliseconds: 300)
            XCTAssertTrue(find.isPresented, close)
            XCTAssertNotEqual(gtk_search_bar_get_search_mode(bar.widget), 0, "\(close): the bar shows again")
        }
    }

    // In a window: every present() (a repeat Ctrl+F too) puts the focus in the field, and the current match is
    // scrolled into view after the view rebuilds.
    func testPresentFocusesAndTheCurrentMatchIsScrolledTo() throws {
        try XCTSkipUnless(gtkDisplay(), "no display")
        let view = RichTextGtkView(markdown: "short")
        let find = RichTextGtkFindController()
        find.bind(view: view)
        let bar = RichTextGtkFindBar(find)
        let window = gtk_window_new()!
        let gtkWindow = UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self)
        gtk_window_set_default_size(gtkWindow, 400, 300)
        let column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        let scrolled = gtk_scrolled_window_new()!
        gtk_widget_set_vexpand(scrolled, 1)
        gtk_scrolled_window_set_child(OpaquePointer(scrolled), widget(view.widget))
        gtk_box_append(UnsafeMutableRawPointer(column).assumingMemoryBound(to: GtkBox.self), widget(bar.widget))
        gtk_box_append(UnsafeMutableRawPointer(column).assumingMemoryBound(to: GtkBox.self), scrolled)
        gtk_window_set_child(gtkWindow, column)
        gtk_window_present(gtkWindow)
        defer {
            gtk_window_destroy(gtkWindow)
        }
        pump(milliseconds: 300)
        let entry = try XCTUnwrap(bar.entryForTests)
        let focusInEntry = {
            guard let focus = gtk_root_get_focus(gtk_widget_get_root(entry)) else {
                return false
            }
            return focus == entry || gtk_widget_is_ancestor(focus, entry) != 0
        }
        find.present()
        pump(milliseconds: 300)
        XCTAssertTrue(focusInEntry())
        gtk_widget_grab_focus(widget(view.widget))
        XCTAssertFalse(focusInEntry())
        find.present()
        pump(milliseconds: 300)
        XCTAssertTrue(focusInEntry(), "a repeat present() focuses the field again")

        find.query = "needle"
        view.setMarkdown((0..<150).map { "Paragraph \($0)." }.joined(separator: "\n\n") + "\n\nneedle")
        pump(milliseconds: 500)
        let adjustment = try XCTUnwrap(gtk_scrolled_window_get_vadjustment(OpaquePointer(scrolled)))
        XCTAssertEqual(find.ranges.count, 1)
        XCTAssertGreaterThan(gtk_adjustment_get_value(adjustment), 0, "the match at the end is scrolled to")
    }

    func testASecondControllerTakesTheViewOver() throws {
        try XCTSkipUnless(gtkDisplay(), "no display")
        let view = RichTextGtkView(markdown: "me and me")
        let first = RichTextGtkFindController()
        first.bind(view: view)
        first.query = "me"
        let second = RichTextGtkFindController()
        second.bind(view: view)
        second.query = "and"
        XCTAssertNil(tagName(in: view, at: 0), "the first controller's matches are gone")
        XCTAssertEqual(tagName(in: view, at: 3), "richtext-find-current")
        first.query = "me me"
        XCTAssertEqual(tagName(in: view, at: 3), "richtext-find-current", "the first no longer paints")
    }

    func testStepButtonsNeedMatches() throws {
        try XCTSkipUnless(gtkDisplay(), "no display")
        let find = RichTextGtkFindController()
        find.bind(text: "abc")
        let bar = RichTextGtkFindBar(find)
        XCTAssertFalse(bar.stepButtonsEnabledForTests)
        find.query = "b"
        XCTAssertTrue(bar.stepButtonsEnabledForTests)
        find.query = "z"
        XCTAssertFalse(bar.stepButtonsEnabledForTests)
    }

    // MARK: - Helpers

    private func widget(_ pointer: OpaquePointer) -> UnsafeMutablePointer<GtkWidget> {
        UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: GtkWidget.self)
    }

    private func pump(milliseconds: Int) {
        let end = g_get_monotonic_time() + gint64(milliseconds) * 1000
        while g_get_monotonic_time() < end {
            if g_main_context_iteration(nil, 0) == 0 {
                usleep(1000)
            }
        }
    }

    // The name of the find tag at `offset` in the view's buffer, if any.
    private func tagName(in view: RichTextGtkView, at offset: Int) -> String? {
        let textView = UnsafeMutableRawPointer(view.widget).assumingMemoryBound(to: GtkTextView.self)
        let buffer = gtk_text_view_get_buffer(textView)!
        let table = gtk_text_buffer_get_tag_table(buffer)!
        var iter = GtkTextIter()
        gtk_text_buffer_get_iter_at_offset(buffer, &iter, Int32(offset))
        for name in ["richtext-find-current", "richtext-find-match"] {
            if let tag = gtk_text_tag_table_lookup(table, name), gtk_text_iter_has_tag(&iter, tag) != 0 {
                return name
            }
        }
        return nil
    }

    private func entryText(_ bar: RichTextGtkFindBar) -> String {
        guard let entry = gtk_search_bar_get_key_capture_widget(bar.widget) ?? firstEntry(bar) else {
            return ""
        }
        return gtk_editable_get_text(OpaquePointer(entry)).map { String(cString: $0) } ?? ""
    }

    private func firstEntry(_ bar: RichTextGtkFindBar) -> UnsafeMutablePointer<GtkWidget>? {
        bar.entryForTests
    }

    private func countText(_ bar: RichTextGtkFindBar) -> String {
        gtk_label_get_text(OpaquePointer(bar.countForTests)).map { String(cString: $0) } ?? ""
    }
}
