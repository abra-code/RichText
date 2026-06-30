// Tests/RichTextViewTests/RichTextSerializerTests.swift

import XCTest
@testable import RichTextView

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
        for needle in ["<h1>", "<strong>", "<em>", "<code>", "<a href=\"https://swift.org\"",
                       "<blockquote>", "<pre><code", "<hr>", "<table>", "<th", "<td"] {
            XCTAssertTrue(html.contains(needle), "HTML missing '\(needle)'")
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
