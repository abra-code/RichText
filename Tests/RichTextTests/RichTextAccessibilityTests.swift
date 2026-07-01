// Tests/RichTextTests/RichTextAccessibilityTests.swift
//
// The VoiceOver linearization: the whole document is exposed as one static-text accessibility element whose
// label comes from RichTextAccessibility.label(for:). These assert the parts a screen reader could not
// recover from the rendered glyphs - image alt text and table structure - plus that visual formatting is
// dropped to plain speech.

import XCTest
@testable import RichText

final class RichTextAccessibilityTests: XCTestCase {

    private func label(_ markdown: String) -> String {
        RichTextAccessibility.label(for: RichTextDocument(markdown: markdown))
    }

    func testImageSpeaksItsAltText() {
        XCTAssertTrue(label("![a napping cat](https://x/c.png)").contains("a napping cat"))
    }

    func testDecorativeImageWithEmptyAltIsSilent() {
        // Empty alt = decorative = nothing to speak, matching web alt="" semantics.
        XCTAssertEqual(label("![](https://x/c.png)"), "")
    }

    func testInlineImageIsSpokenInFlow() {
        let l = label("Here is ![a sales chart](https://x/c.png) for Q3.")
        XCTAssertTrue(l.contains("Here is"), l)
        XCTAssertTrue(l.contains("a sales chart"), l)
    }

    func testVisualFormattingIsDroppedToPlainSpeech() {
        let l = label("A **bold** and *italic* and `code` word, plus a [link text](https://x).")
        XCTAssertFalse(l.contains("*"), l)
        XCTAssertFalse(l.contains("`"), l)
        XCTAssertTrue(l.contains("bold"))
        XCTAssertTrue(l.contains("italic"))
        XCTAssertTrue(l.contains("link text"))
    }

    func testTableReadsRowByRowWithCommaSeparatedCells() {
        let md = """
        | Name | Role |
        | --- | --- |
        | Ada | Author |
        | Grace | Admiral |
        """
        let l = label(md)
        XCTAssertTrue(l.contains("Name, Role"), l)
        XCTAssertTrue(l.contains("Ada, Author"), l)
        XCTAssertTrue(l.contains("Grace, Admiral"), l)
    }

    func testHeadingAndParagraphSeparatedByNewlinePauses() {
        XCTAssertEqual(label("# Title\n\nA paragraph."), "Title\nA paragraph.")
    }

    func testBlockquoteAndListContentIsIncluded() {
        let l = label("> quoted wisdom\n\n- first item\n- second item")
        XCTAssertTrue(l.contains("quoted wisdom"), l)
        XCTAssertTrue(l.contains("first item"), l)
        XCTAssertTrue(l.contains("second item"), l)
    }

    func testCodeBlockContentIsIncluded() {
        let md = """
        ```swift
        let answer = 42
        ```
        """
        XCTAssertTrue(label(md).contains("let answer = 42"))
    }
}
