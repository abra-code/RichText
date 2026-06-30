// Tests/RichTextViewTests/RichTextMarkdownParserTests.swift

import XCTest
@testable import RichTextView

final class RichTextMarkdownParserTests: XCTestCase {

    private func parse(_ md: String) -> [RichTextBlock] {
        return RichTextMarkdownParser.parse(md)
    }

    func testParagraphAndInline() {
        XCTAssertEqual(parse("*a* **b** `c`"),
                       [.paragraph([.emphasis([.text("a")]), .text(" "),
                                    .strong([.text("b")]), .text(" "), .code("c")])])
    }

    func testHeadingAndLink() {
        XCTAssertEqual(parse("# Title"), [.heading(level: 1, [.text("Title")])])
        XCTAssertEqual(parse("[x](https://swift.org)"),
                       [.paragraph([.link(text: [.text("x")], url: "https://swift.org")])])
    }

    func testUnterminatedSpanIsLiteral() {
        XCTAssertEqual(parse("a **bold and more"), [.paragraph([.text("a **bold and more")])])
    }

    func testFencedCode() {
        XCTAssertEqual(parse("```swift\nlet x = 1\n```"),
                       [.codeBlock(language: "swift", code: "let x = 1")])
    }

    func testListNestedAndTable() {
        guard case .list(_, _, _, let items)? = parse("- a\n  - b\n- c").first else {
            return XCTFail("expected list")
        }
        XCTAssertEqual(items.count, 2)

        guard case .table(let headers, let aligns, let rows)? = parse("| A | B |\n| - | :-: |\n| 1 | 2 |").first else {
            return XCTFail("expected table")
        }
        XCTAssertEqual(headers.map { $0.plainText }, ["A", "B"])
        XCTAssertEqual(aligns, [.none, .center])
        XCTAssertEqual(rows.first?.map { $0.plainText }, ["1", "2"])
    }

    func testDocumentConvenience() {
        XCTAssertEqual(RichTextDocument(markdown: "# Hi").blocks, [.heading(level: 1, [.text("Hi")])])
    }
}
