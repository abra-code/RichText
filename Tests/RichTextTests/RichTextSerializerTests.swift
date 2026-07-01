// Tests/RichTextTests/RichTextSerializerTests.swift

import XCTest
@testable import RichText

final class RichTextSerializerTests: XCTestCase {

    private let richDoc = RichTextDocument(markdown: """
    # Title

    Para with **bold**, *italic*, `code`, and [link](https://swift.org).

    > a quote

    ```swift
    let x = 1
    ```

    | Feature | Status |
    | --- | :-: |
    | Code | ok |

    ---
    """)

    // The Markdown serializer is the parser's inverse for the supported subset.
    func testMarkdownRoundTripStable() {
        let simple = RichTextDocument(markdown: "# Hi\n\nA **b** and `c`.\n\n| A | B |\n| --- | ---: |\n| 1 | 2 |")
        let reparsed = RichTextDocument(markdown: RichTextMarkdownSerializer.string(from: simple))
        XCTAssertEqual(reparsed, simple)
    }

    func testHTMLContainsBlocksAndInline() {
        let html = RichTextHTMLSerializer.fragment(from: richDoc)
        // Tag prefixes (the tags now carry inline style="..." attributes).
        for needle in ["<h1", "<strong>", "<em>", "<code", "<a href=\"https://swift.org\"",
                       "<blockquote", "<pre", "<hr", "<table", "<th", "<td"] {
            XCTAssertTrue(html.contains(needle), "HTML missing '\(needle)'")
        }
    }

    // MARK: - Image copy (HTML data: URIs)

    private let imageDoc = RichTextDocument(markdown: "![cat](https://x.test/cat.png)")

    func testHTMLEmbedsImageAsDataURIWhenResolved() {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let resolver: RichTextImageResolver = { url in
            url == "https://x.test/cat.png" ? RichTextInlineImage(data: bytes, format: .png, displaySize: CGSize(width: 40, height: 30)) : nil
        }
        let html = RichTextHTMLSerializer.fragment(from: imageDoc, images: resolver)
        XCTAssertTrue(html.contains("src=\"data:image/png;base64," + bytes.base64EncodedString()),
                      "expected an embedded PNG data: URI, got \(html)")
    }

    func testHTMLEmbedsJPEGWithJPEGMimeType() {
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let resolver: RichTextImageResolver = { _ in RichTextInlineImage(data: bytes, format: .jpeg, displaySize: CGSize(width: 40, height: 30)) }
        let html = RichTextHTMLSerializer.fragment(from: imageDoc, images: resolver)
        XCTAssertTrue(html.contains("src=\"data:image/jpeg;base64," + bytes.base64EncodedString()),
                      "expected a JPEG data: URI (photos stay compact), got \(html)")
    }

    func testHTMLEmbedsGIFWithGIFMimeType() {
        // An animated GIF travels unchanged in HTML (data:image/gif) - HTML targets keep the animation.
        let bytes = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])   // GIF89a
        let resolver: RichTextImageResolver = { _ in RichTextInlineImage(data: bytes, format: .gif, displaySize: CGSize(width: 20, height: 20)) }
        let html = RichTextHTMLSerializer.fragment(from: imageDoc, images: resolver)
        XCTAssertTrue(html.contains("src=\"data:image/gif;base64," + bytes.base64EncodedString()),
                      "expected a GIF data: URI, got \(html)")
    }

    func testHTMLFallsBackToURLWhenImageNotResolved() {
        let html = RichTextHTMLSerializer.fragment(from: imageDoc)   // default resolver returns nil
        XCTAssertTrue(html.contains("src=\"https://x.test/cat.png\""), "expected URL fallback, got \(html)")
        XCTAssertFalse(html.contains("data:image"), "should not embed data when unresolved")
    }

    func testHTMLStylesAreInline() {
        let html = RichTextHTMLSerializer.fragment(from: richDoc)
        // The look travels as inline styles so it survives paste into stylesheet-stripping targets.
        for needle in ["border-collapse:collapse", "border:1px solid", "background:#f0f0f0",
                       "border-left:3px solid", "border-top:1px solid", "font-size:1.6em"] {
            XCTAssertTrue(html.contains(needle), "HTML missing style '\(needle)'")
        }
    }

    func testRTFContainsRealTableAndStyles() {
        let rtf = RichTextRTFSerializer.string(from: richDoc)
        for needle in ["\\rtf1", "\\trowd", "\\cellx", "\\intbl", "\\cell", "\\row", "HYPERLINK"] {
            XCTAssertTrue(rtf.contains(needle), "RTF missing '\(needle)'")
        }
        // A two-column table emits at least two \cellx per row and a \row per (header + 1 row).
        XCTAssertGreaterThanOrEqual(rtf.components(separatedBy: "\\row").count - 1, 2)
    }

    func testRTFEscaping() {
        let doc = RichTextDocument(blocks: [.paragraph([.text("a {b} \\ c")])])
        let rtf = RichTextRTFSerializer.string(from: doc)
        XCTAssertTrue(rtf.contains("a \\{b\\} \\\\ c"))
    }
}
