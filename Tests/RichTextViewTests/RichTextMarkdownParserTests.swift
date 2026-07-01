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

    // MARK: - Autolinking

    private func inlines(_ md: String) -> [RichTextInline] {
        guard case .paragraph(let nodes)? = parse(md).first else {
            return []
        }
        return nodes
    }

    func testAutolinkBareURL() {
        let nodes = inlines("see https://swift.org now")
        XCTAssertEqual(nodes.count, 3)
        XCTAssertEqual(nodes.first, .text("see "))
        XCTAssertEqual(nodes.last, .text(" now"))
        guard case .link(let text, let url) = nodes[1] else {
            return XCTFail("expected a link")
        }
        XCTAssertEqual(text.plainText, "https://swift.org")
        XCTAssertTrue(url.contains("swift.org"), "url was \(url)")
    }

    func testAutolinkWWWGetsScheme() {
        guard case .link(let text, let url)? = inlines("visit www.swift.org").last else {
            return XCTFail("expected a link")
        }
        XCTAssertEqual(text.plainText, "www.swift.org")
        XCTAssertTrue(url.hasPrefix("http"), "url was \(url)")
    }

    func testAutolinkExcludesTrailingPunctuation() {
        let nodes = inlines("go to https://swift.org.")
        XCTAssertEqual(nodes.last, .text("."))
        guard case .link(let text, _) = nodes[1] else {
            return XCTFail("expected a link")
        }
        XCTAssertEqual(text.plainText, "https://swift.org")
    }

    func testAutolinkInsideBold() {
        guard case .strong(let children)? = inlines("**https://swift.org**").first,
              case .link(let text, _)? = children.first else {
            return XCTFail("expected a link inside strong")
        }
        XCTAssertEqual(text.plainText, "https://swift.org")
    }

    func testURLInCodeIsNotLinked() {
        XCTAssertEqual(parse("`https://swift.org`"), [.paragraph([.code("https://swift.org")])])
    }

    func testExplicitLinkNotDoubleLinked() {
        XCTAssertEqual(parse("[https://swift.org](https://swift.org)"),
                       [.paragraph([.link(text: [.text("https://swift.org")], url: "https://swift.org")])])
    }

    func testPlainTextUnchanged() {
        XCTAssertEqual(parse("just words, no links here"),
                       [.paragraph([.text("just words, no links here")])])
    }
}
