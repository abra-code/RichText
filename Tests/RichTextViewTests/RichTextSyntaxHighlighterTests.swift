// Tests/RichTextViewTests/RichTextSyntaxHighlighterTests.swift

import XCTest
@testable import RichTextView

final class RichTextSyntaxHighlighterTests: XCTestCase {

    private func tokens(_ code: String, _ language: String?) -> [RichTextSyntaxHighlighter.Token] {
        return RichTextSyntaxHighlighter.tokenize(code, profile: SyntaxProfile.profile(for: language))
    }

    private func text(_ code: String, _ range: NSRange) -> String {
        return (code as NSString).substring(with: range)
    }

    func testKeywordStringNumberComment() {
        let code = "// hi\nlet x = 42\nlet s = \"hello\""
        let found = tokens(code, "swift")
        XCTAssertTrue(found.contains { $0.type == .comment && text(code, $0.range) == "// hi" })
        XCTAssertTrue(found.contains { $0.type == .keyword && text(code, $0.range) == "let" })
        XCTAssertTrue(found.contains { $0.type == .number && text(code, $0.range) == "42" })
        XCTAssertTrue(found.contains { $0.type == .string && text(code, $0.range) == "\"hello\"" })
    }

    func testStringEscapeDoesNotEndEarly() {
        let code = "\"a\\\"b\""              // the literal "a\"b"
        let strings = tokens(code, "swift").filter { $0.type == .string }
        XCTAssertEqual(strings.count, 1)
        XCTAssertEqual(text(code, strings[0].range), code)
    }

    func testBlockCommentSpansLines() {
        let code = "/* a\n b */ let"
        let found = tokens(code, "swift")
        XCTAssertTrue(found.contains { $0.type == .comment && text(code, $0.range) == "/* a\n b */" })
        XCTAssertTrue(found.contains { $0.type == .keyword && text(code, $0.range) == "let" })
    }

    func testCommentStyleIsLanguageSpecific() {
        let code = "# c\nx = 1"
        XCTAssertTrue(tokens(code, "python").contains { $0.type == .comment && text(code, $0.range) == "# c" })
        // '#' is not a comment in Swift (which uses //), so the Swift profile finds no comment here.
        XCTAssertFalse(tokens(code, "swift").contains { $0.type == .comment })
    }

    func testNumberDoesNotSwallowRangeOperator() {
        // "0...5" must not be lexed as one number; only "0" and "5" are numbers.
        let code = "for i in 0...5 {}"
        let numbers = tokens(code, "swift").filter { $0.type == .number }.map { text(code, $0.range) }
        XCTAssertEqual(numbers, ["0", "5"])
    }

    func testAppliesColorThroughBuilder() {
        let doc = RichTextDocument(markdown: "```swift\nreturn 0\n```")
        let attributed = RichTextAttributedString.make(doc, theme: .default)
        let range = (attributed.string as NSString).range(of: "return")
        XCTAssertGreaterThan(range.length, 0)
        let color = attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? RTVColor
        XCTAssertEqual(color, RTVSyntaxColors.keyword)
    }

    func testDisabledByThemeLeavesLabelColor() {
        let doc = RichTextDocument(markdown: "```swift\nreturn 0\n```")
        var theme = RichTextTheme.default
        theme.syntaxHighlighting = false
        let attributed = RichTextAttributedString.make(doc, theme: theme)
        let range = (attributed.string as NSString).range(of: "return")
        let color = attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? RTVColor
        XCTAssertEqual(color, RTVColors.label)
    }
}
