// Tests/RichTextTests/RichTextAttributedStringImportTests.swift
//
// Verifies RichTextDocument(attributedString:) reconstructs the model from a Foundation AttributedString.
// Inputs are built with AttributedString(markdown:options:) using .full interpreted syntax (so block-level
// Markdown and GFM extensions - strikethrough, tables - are parsed) which is the canonical, reliable source
// of PresentationIntent. Two tests build intents by hand (PresentationIntent init) to pin down the parts of
// the mapping that Markdown parsing represents ambiguously (thematic break, nesting order).

import XCTest
import Foundation
import SwiftUI
@testable import RichText

final class RichTextAttributedStringImportTests: XCTestCase {

    private static let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)

    private func parse(_ markdown: String) throws -> [RichTextBlock] {
        let attributed = try AttributedString(markdown: markdown, options: Self.options)
        return RichTextDocument(attributedString: attributed).blocks
    }

    // MARK: - Headings and inline styling

    func testHeadingThenParagraph() throws {
        XCTAssertEqual(try parse("# Title\n\nHello world"),
                       [.heading(level: 1, [.text("Title")]),
                        .paragraph([.text("Hello world")])])
    }

    func testInlineStrong() throws {
        XCTAssertEqual(try parse("**bold**"), [.paragraph([.strong([.text("bold")])])])
    }

    func testInlineEmphasis() throws {
        XCTAssertEqual(try parse("*italic*"), [.paragraph([.emphasis([.text("italic")])])])
    }

    func testInlineCode() throws {
        XCTAssertEqual(try parse("`code`"), [.paragraph([.code("code")])])
    }

    func testInlineStrikethrough() throws {
        // GFM strikethrough - available because interpretedSyntax is .full.
        XCTAssertEqual(try parse("~~strike~~"), [.paragraph([.strikethrough([.text("strike")])])])
    }

    func testInlineLink() throws {
        XCTAssertEqual(try parse("[link](https://x.test)"),
                       [.paragraph([.link(text: [.text("link")], url: "https://x.test")])])
    }

    // Exact structure for text interleaved with a styled span: the plain runs around the bold keep their
    // spaces and stay separate inline nodes.
    func testParagraphMixesTextAndStrong() throws {
        XCTAssertEqual(try parse("a **b** c"),
                       [.paragraph([.text("a "), .strong([.text("b")]), .text(" c")])])
    }

    // The full heading + paragraph with every inline style + a link (as the task specifies). Run boundaries
    // around interior spaces are a Foundation detail, so this asserts the recovered plain text plus the
    // presence of each styled node rather than an exact node-by-node sequence (see testParagraphMixesText-
    // AndStrong for an exact-sequence check).
    func testHeadingAndFullyStyledParagraph() throws {
        let blocks = try parse("# Heading\n\nHello **bold** *italic* `code` ~~strike~~ [link](https://x.test)")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.first, .heading(level: 1, [.text("Heading")]))
        guard case .paragraph(let nodes)? = blocks.last else {
            return XCTFail("expected a paragraph")
        }
        XCTAssertEqual(nodes.plainText, "Hello bold italic code strike link")
        XCTAssertTrue(nodes.contains(.strong([.text("bold")])))
        XCTAssertTrue(nodes.contains(.emphasis([.text("italic")])))
        XCTAssertTrue(nodes.contains(.code("code")))
        XCTAssertTrue(nodes.contains(.strikethrough([.text("strike")])))
        XCTAssertTrue(nodes.contains(.link(text: [.text("link")], url: "https://x.test")))
    }

    // MARK: - Lists

    func testUnorderedList() throws {
        XCTAssertEqual(try parse("- one\n- two"),
                       [.list(ordered: false, start: 1, tight: true, items: [
                            [.paragraph([.text("one")])],
                            [.paragraph([.text("two")])],
                       ])])
    }

    func testOrderedListWithOrdinals() throws {
        XCTAssertEqual(try parse("1. first\n2. second"),
                       [.list(ordered: true, start: 1, tight: true, items: [
                            [.paragraph([.text("first")])],
                            [.paragraph([.text("second")])],
                       ])])
    }

    // MARK: - Block quote

    func testBlockQuote() throws {
        XCTAssertEqual(try parse("> quoted"),
                       [.blockQuote([.paragraph([.text("quoted")])])])
    }

    // MARK: - Table (headers, per-column alignment, row cells)

    func testTableWithAlignments() throws {
        let markdown = """
        | Left | Center | Right |
        | :--- | :----: | ----: |
        | a | b | c |
        """
        guard case .table(let headers, let alignments, let rows)? = try parse(markdown).first else {
            return XCTFail("expected a table")
        }
        XCTAssertEqual(headers.map { $0.plainText }, ["Left", "Center", "Right"])
        XCTAssertEqual(alignments, [.left, .center, .right])
        XCTAssertEqual(rows.map { $0.map { $0.plainText } }, [["a", "b", "c"]])
    }

    // MARK: - Code block

    func testFencedCodeBlock() throws {
        guard case .codeBlock(let language, let code)? = try parse("```swift\nlet x = 1\n```").first else {
            return XCTFail("expected a code block")
        }
        XCTAssertEqual(language, "swift")
        // Trailing newline handling is normalized by the importer; compare on trimmed content to be robust.
        XCTAssertEqual(code.trimmingCharacters(in: .newlines), "let x = 1")
    }

    // MARK: - Thematic break

    // Foundation emits no run for a zero-content block, so a Markdown "---" may not survive as a run. This
    // asserts the reliable part (the surrounding paragraphs) and that no rule is mis-reconstructed as some
    // other block; the deterministic mapping of the .thematicBreak intent itself is pinned in
    // testThematicBreakIntentIsReconstructed below.
    func testThematicBreakFromMarkdown() throws {
        let blocks = try parse("before\n\n---\n\nafter")
        let paragraphs = blocks.filter { if case .paragraph = $0 { return true } else { return false } }
        XCTAssertEqual(paragraphs, [.paragraph([.text("before")]), .paragraph([.text("after")])])
        for block in blocks where !isParagraph(block) {
            XCTAssertEqual(block, .thematicBreak, "a non-paragraph block here must be the rule")
        }
    }

    // MARK: - Deterministic mapping via hand-built PresentationIntent

    // Pins the .thematicBreak mapping independently of how Markdown parsing represents rules.
    func testThematicBreakIntentIsReconstructed() {
        var before = AttributedString("before")
        before.presentationIntent = PresentationIntent(.paragraph, identity: 1, parent: nil)
        var rule = AttributedString("\u{00A0}")   // needs some text so the intent exists on a run
        rule.presentationIntent = PresentationIntent(.thematicBreak, identity: 2, parent: nil)
        var after = AttributedString("after")
        after.presentationIntent = PresentationIntent(.paragraph, identity: 3, parent: nil)

        let blocks = RichTextDocument(attributedString: before + rule + after).blocks
        XCTAssertEqual(blocks, [.paragraph([.text("before")]), .thematicBreak, .paragraph([.text("after")])])
    }

    // Confirms component ordering: a paragraph whose parent intent is a blockQuote must nest as
    // blockQuote -> paragraph (this fails loudly if the components array order were misread).
    func testNestedIntentOrderIsReconstructed() {
        let quote = PresentationIntent(.blockQuote, identity: 1, parent: nil)
        var text = AttributedString("hi")
        text.presentationIntent = PresentationIntent(.paragraph, identity: 2, parent: quote)

        XCTAssertEqual(RichTextDocument(attributedString: text).blocks,
                       [.blockQuote([.paragraph([.text("hi")])])])
    }

    // MARK: - NSAttributedString bridge and view initializer

    // A plain NSAttributedString carries no PresentationIntent, so the whole thing collapses to a paragraph.
    func testNSAttributedStringBridgeCollapsesToParagraph() {
        let ns = NSAttributedString(string: "just text")
        XCTAssertEqual(RichTextDocument(nsAttributedString: ns).blocks, [.paragraph([.text("just text")])])
    }

    // Smoke test: the introspecting view initializer builds without trapping.
    @MainActor
    func testIntrospectingViewInitializerBuilds() throws {
        let attributed = try AttributedString(markdown: "# Hi\n\nbody", options: Self.options)
        _ = RichText(introspecting: attributed)
    }

    // MARK: - Helpers

    private func isParagraph(_ block: RichTextBlock) -> Bool {
        if case .paragraph = block { return true } else { return false }
    }
}
