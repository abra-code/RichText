// Tests/RichTextTests/Gtk/RichTextGtkBuilderTests.swift
//
// The GTK renderer's buffer: the text a document becomes and the tag properties on it. No display is needed:
// a GtkTextBuffer and its tags are plain objects, and Pango's default font map measures table cells.

import XCTest
import Foundation
import CRichTextGtk
@testable import RichText

@MainActor
final class RichTextGtkBuilderTests: XCTestCase {

    private var buffer: UnsafeMutablePointer<GtkTextBuffer>!
    private var links: [RichTextGtkLink] = []

    override func tearDown() async throws {
        await MainActor.run {
            if let buffer {
                g_object_unref(UnsafeMutableRawPointer(buffer))
            }
            buffer = nil
        }
    }

    private var lastBuilder: RichTextGtkBuilder?
    private let palette = RichTextGtkPalette(foreground: GdkRGBA(red: 0, green: 0, blue: 0, alpha: 1))

    // Builds `markdown` and returns the buffer's text.
    private func build(_ markdown: String, theme: RichTextTheme = .default) -> String {
        if let buffer {
            g_object_unref(UnsafeMutableRawPointer(buffer))
        }
        buffer = gtk_text_buffer_new(nil)
        let fontMap = pango_cairo_font_map_get_default()
        let pango = pango_font_map_create_context(fontMap)!
        defer {
            g_object_unref(UnsafeMutableRawPointer(pango))
        }
        let builder = RichTextGtkBuilder(buffer: buffer, theme: theme, palette: palette, pango: pango)
        lastBuilder = builder
        builder.build(RichTextDocument(markdown: markdown))
        links = builder.links
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        let text = gtk_text_buffer_get_slice(buffer, &start, &end, 1)!   // a slice keeps U+FFFC for anchors
        defer {
            g_free(text)
        }
        return String(cString: text)
    }

    // The character offset of the first `needle` in the buffer's text.
    private func offset(of needle: String, in text: String) -> Int {
        let range = text.range(of: needle)!
        return text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: range.lowerBound)
    }

    // The value of a property on any tag at `offset` whose "<name>-set" flag is on, or nil.
    private func tagProperty<T>(_ name: String, at offset: Int, read: (UnsafeMutablePointer<GValue>) -> T) -> T? {
        var iter = GtkTextIter()
        gtk_text_buffer_get_iter_at_offset(buffer, &iter, Int32(offset))
        guard let list = gtk_text_iter_get_tags(&iter) else {
            return nil
        }
        defer {
            g_slist_free(list)
        }
        var node: UnsafeMutablePointer<GSList>? = list
        var found: T?
        while let current = node {
            let object = current.pointee.data.assumingMemoryBound(to: GObject.self)
            if let spec = g_object_class_find_property(UnsafeMutableRawPointer(object.pointee.g_type_instance.g_class)
                                                        .assumingMemoryBound(to: GObjectClass.self), name) {
                var flag = GValue()
                g_value_init(&flag, GType(5 << G_TYPE_FUNDAMENTAL_SHIFT))
                // The flag of an -rgba color is the color's plain name's, and size-points' is size's.
                let setName = (name == "size-points" ? "size" : name.hasSuffix("-rgba") ? String(name.dropLast(5)) : name) + "-set"
                g_object_get_property(object, setName, &flag)
                if g_value_get_boolean(&flag) != 0 {
                    var value = GValue()
                    g_value_init(&value, spec.pointee.value_type)
                    g_object_get_property(object, name, &value)
                    found = read(&value)
                    g_value_unset(&value)
                }
                g_value_unset(&flag)
            }
            node = current.pointee.next
        }
        return found
    }

    private func weight(at offset: Int) -> Int32? {
        tagProperty("weight", at: offset) { g_value_get_int($0) }
    }

    private func family(at offset: Int) -> String? {
        tagProperty("family", at: offset) { String(cString: g_value_get_string($0)) }
    }

    private func foreground(at offset: Int) -> GdkRGBA? {
        tagProperty("foreground-rgba", at: offset) { g_value_get_boxed($0).assumingMemoryBound(to: GdkRGBA.self).pointee }
    }

    // MARK: - Tests

    func testBlocksBecomeLinesWithoutATrailingBreak() {
        let text = build("# Title\n\nPara with **bold** and `code`.\n\n---\n\n> quoted")
        XCTAssertEqual(text, "Title\nPara with bold and code.\n \n \n \nquoted", "the rule is a hairline line between two spacer lines")
        XCTAssertEqual(build("Text\n\n---"), "Text\n \n ", "no spacer line after a last rule")
    }

    func testInlineAndHeadingStyles() {
        let text = build("# Title\n\nPara with **bold**, *it*, ~~gone~~ and `code`.")
        XCTAssertEqual(weight(at: offset(of: "Title", in: text)), 700, "headings are bold")
        XCTAssertNotNil(tagProperty("scale", at: 0) { g_value_get_double($0) }.flatMap { $0 > 1.5 ? $0 : nil },
                        "a level-1 heading is larger")
        XCTAssertEqual(weight(at: offset(of: "bold", in: text)), 700)
        XCTAssertNil(weight(at: offset(of: "Para", in: text)))
        XCTAssertEqual(tagProperty("style", at: offset(of: ", it,", in: text) + 2) { g_value_get_enum($0) },
                       Int32(PANGO_STYLE_ITALIC.rawValue))
        XCTAssertEqual(tagProperty("strikethrough", at: offset(of: "gone", in: text)) { g_value_get_boolean($0) }, 1)
        XCTAssertEqual(family(at: offset(of: "code", in: text)), "monospace")
    }

    func testCodeBlockIsColoredFromTheSharedTokens() {
        let text = build("```swift\nlet x = 42 // note\n```")
        XCTAssertEqual(text, "let x = 42 // note", "no spacer line after a last code block")
        XCTAssertEqual(family(at: 0), "monospace")
        XCTAssertEqual(foreground(at: offset(of: "let", in: text)), palette.syntaxKeyword)
        XCTAssertEqual(foreground(at: offset(of: "42", in: text)), palette.syntaxNumber)
        XCTAssertEqual(foreground(at: offset(of: "// note", in: text)), palette.syntaxComment)
        XCTAssertNil(foreground(at: offset(of: "x", in: text)))
    }

    func testSyntaxHighlightingOffFollowsTheTheme() {
        var theme = RichTextTheme.default
        theme.syntaxHighlighting = false
        let text = build("```swift\nlet x\n```", theme: theme)
        XCTAssertNil(foreground(at: offset(of: "let", in: text)))
    }

    // Offsets are characters: a link after an astral emoji still lands on its text.
    func testLinksAreRecordedOnlyForAllowedTargets() {
        let text = build("\u{1F600} [site](https://swift.org) and [bad](javascript:alert(1))")
        XCTAssertEqual(links.count, 1)
        let link = links[0]
        XCTAssertEqual(link.url, URL(string: "https://swift.org"))
        let start = offset(of: "site", in: text)
        XCTAssertEqual(link.range, start..<(start + 4))
        XCTAssertEqual(foreground(at: start), palette.link)
        XCTAssertNil(foreground(at: offset(of: "bad", in: text)), "a disallowed link stays plain text")
    }

    func testListsAndTablesUseTabStops() {
        let text = build("- one\n- two\n\n| A | Bee |\n|---|--:|\n| 1 | 2 |")
        XCTAssertEqual(text, "\u{2022}\tone\n\u{2022}\ttwo\n\tA\tBee\n\t1\t2")
        let listTabs = tagProperty("tabs", at: 0) { $0 } != nil
        XCTAssertTrue(listTabs, "a list line has its content tab stop")
        XCTAssertEqual(weight(at: offset(of: "Bee", in: text)), 700, "the header row is bold")
        let rowTabs = tagProperty("tabs", at: offset(of: "\t1", in: text)) { value -> [Int32] in
            let array = OpaquePointer(g_value_get_boxed(value))
            return (0..<pango_tab_array_get_size(array)).map { index in
                var alignment = PANGO_TAB_LEFT
                var location: Int32 = 0
                pango_tab_array_get_tab(array, index, &alignment, &location)
                return location
            }
        }
        XCTAssertEqual(rowTabs?.count, 2)
        if let tabs = rowTabs {
            XCTAssertLessThan(tabs[0], tabs[1], "columns run left to right")
        }
    }

    // The tab stop of each column after the first, in pixels, on the table row holding `needle`.
    private func rowTabs(at needle: String, in text: String) -> [Int32] {
        tagProperty("tabs", at: offset(of: needle, in: text)) { value -> [Int32] in
            let array = OpaquePointer(g_value_get_boxed(value))
            return (0..<pango_tab_array_get_size(array)).map { index in
                var alignment = PANGO_TAB_LEFT
                var location: Int32 = 0
                pango_tab_array_get_tab(array, index, &alignment, &location)
                return location
            }
        } ?? []
    }

    // A column is as wide as its cells are drawn: monospace code is wider than the same text in the body font.
    func testStyledCellsWidenTheirColumn() {
        let plain = build("| A | B |\n|---|---|\n| iiiiiiiiiiii | x |")
        let plainTabs = rowTabs(at: "\tx", in: plain)
        let code = build("| A | B |\n|---|---|\n| `iiiiiiiiiiii` | x |")
        let codeTabs = rowTabs(at: "\tx", in: code)
        XCTAssertEqual(plainTabs.count, 2)
        XCTAssertEqual(codeTabs.count, 2)
        if plainTabs.count == 2 && codeTabs.count == 2 {
            XCTAssertGreaterThan(codeTabs[1], plainTabs[1])
        }
    }

    // Inline code in a heading takes the code size whether a heading or inline code comes first.
    func testInlineCodeInAHeadingIsCodeSizedInAnyOrder() {
        var theme = RichTextTheme.default
        theme.baseFontSize = 20
        for markdown in ["`a`\n\n# Head `x`", "# One\n\n`a`\n\n# Head `x`"] {
            let text = build(markdown, theme: theme)
            let size = tagProperty("size-points", at: offset(of: "x", in: text)) { g_value_get_double($0) }
            XCTAssertEqual(size ?? 0, 20 * RichTextGtkBuilder.codeScale, accuracy: 0.01, markdown)
        }
    }

    // A NUL in the source would cut the C string short and shift every later tag; it shows as U+FFFD.
    func testNulDoesNotShiftLaterOffsets() {
        let text = build("a\u{0}b **bold**")
        XCTAssertEqual(text, "a\u{FFFD}b bold")
        XCTAssertEqual(weight(at: offset(of: "bold", in: text)), 700)
        XCTAssertNil(weight(at: offset(of: "b ", in: text)))
    }

    func testBaseFontSizeSetsPointSizes() {
        var theme = RichTextTheme.default
        theme.baseFontSize = 20
        let text = build("# Big\n\nbody `code`", theme: theme)
        let heading = tagProperty("size-points", at: 0) { g_value_get_double($0) }
        let body = tagProperty("size-points", at: offset(of: "body", in: text)) { g_value_get_double($0) }
        XCTAssertEqual(body, 20)
        XCTAssertEqual(heading ?? 0, 20 * 22.0 / 13, accuracy: 0.01)
    }

    // MARK: - Images

    // An image is one character (an anchor for its widget), recorded with its alt text and URL.
    func testImagesBecomeAnchors() {
        let text = build("See ![a cat](https://x.test/cat.png) here")
        XCTAssertEqual(text, "See \u{FFFC} here")
        let images = lastBuilder?.images ?? []
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.offset, 4)
        XCTAssertEqual(images.first?.alt, "a cat")
        XCTAssertEqual(images.first?.url, URL(string: "https://x.test/cat.png"))
    }

    // MARK: - Links and colors

    func testLinkSplitOverStyledRunsIsOneLink() {
        let text = build("[a **b** c](https://swift.org) d")
        let start = offset(of: "a b c", in: text)
        XCTAssertEqual(links, [RichTextGtkLink(range: start..<(start + 5), url: URL(string: "https://swift.org")!)])
    }

    // A style change recolors the tags in place: the text and its tags stay, the colors change.
    func testRecolorChangesThePaletteColorsInPlace() {
        let text = build("```swift\nlet x\n```\n\n[go](https://swift.org) and `code`")
        let dark = RichTextGtkPalette(foreground: GdkRGBA(red: 1, green: 1, blue: 1, alpha: 1))
        XCTAssertNotEqual(dark.syntaxKeyword, palette.syntaxKeyword)
        lastBuilder?.recolor(dark)
        XCTAssertEqual(foreground(at: offset(of: "let", in: text)), dark.syntaxKeyword)
        XCTAssertEqual(foreground(at: offset(of: "go", in: text)), dark.link)
        XCTAssertEqual(tagProperty("background-rgba", at: offset(of: "code", in: text)) {
            g_value_get_boxed($0).assumingMemoryBound(to: GdkRGBA.self).pointee
        }, dark.codeFill)
    }
}

extension GdkRGBA: @retroactive Equatable {
    public static func == (a: GdkRGBA, b: GdkRGBA) -> Bool {
        a.red == b.red && a.green == b.green && a.blue == b.blue && a.alpha == b.alpha
    }
}
