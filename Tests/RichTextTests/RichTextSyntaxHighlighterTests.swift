// Tests/RichTextTests/RichTextSyntaxHighlighterTests.swift

import XCTest
@testable import RichText

final class RichTextSyntaxHighlighterTests: XCTestCase {

    private func tokens(_ code: String, _ language: String?) -> [RichTextSyntaxHighlighter.Token] {
        return RichTextSyntaxHighlighter.tokenize(code, profile: SyntaxProfile.profile(for: language))
    }

    // The token's text by its scalar range, checked against its UTF-16 range: both must name the same text.
    private func text(_ code: String, _ token: RichTextSyntaxHighlighter.Token) -> String {
        let scalars = Array(code.unicodeScalars)[token.scalarRange]
        let byScalars = String(String.UnicodeScalarView(scalars))
        let units = Array(code.utf16)[token.utf16Range]
        XCTAssertEqual(String(decoding: units, as: UTF16.self), byScalars, "the two ranges disagree")
        return byScalars
    }

    func testKeywordStringNumberComment() {
        let code = "// hi\nlet x = 42\nlet s = \"hello\""
        let found = tokens(code, "swift")
        XCTAssertTrue(found.contains { $0.type == .comment && text(code, $0) == "// hi" })
        XCTAssertTrue(found.contains { $0.type == .keyword && text(code, $0) == "let" })
        XCTAssertTrue(found.contains { $0.type == .number && text(code, $0) == "42" })
        XCTAssertTrue(found.contains { $0.type == .string && text(code, $0) == "\"hello\"" })
    }

    func testABlockWithNoLanguageIsNotHighlighted() {
        // A commit message in a fenced block: no string from one apostrophe to the next, no comment at "#"
        let prose = "Linux: applets join the desktop's app list, with their icon\n\nso GNOME's Apps lists it # and 42"
        XCTAssertTrue(tokens(prose, nil).isEmpty)
        XCTAssertTrue(tokens(prose, "").isEmpty)
        for plain in ["text", "txt", "plain", "PlainText", " text "] {
            XCTAssertTrue(tokens("let x = 'a'", plain).isEmpty, plain)
        }
    }

    func testAnApostropheInAWordStartsNoStringInAnUnknownLanguage() {
        let code = "the desktop's list, GNOME's apps: 'quoted' and x='y'"
        let strings = tokens(code, "unknownlang").filter { $0.type == .string }.map { text(code, $0) }
        XCTAssertEqual(strings, ["'quoted'", "'y'"])
        // A letter with a combining mark, a letter outside the BMP, a superscript digit, a keycap: apostrophes too;
        // after an emoji a "'" opens a string (the Kotlin port reads UTF-16 and must agree)
        let unicode = "cafe\u{301}'s \u{1D49C}'s x\u{B2}'s 1\u{FE0F}\u{20E3}'s \u{1F600}'y'"
        XCTAssertEqual(tokens(unicode, "unknownlang").filter { $0.type == .string }.map { text(unicode, $0) }, ["'y'"])
        // A real language keeps its rules: Python's f'...' is a string after a letter
        let python = "s = f'{name}'"
        XCTAssertEqual(tokens(python, "python").filter { $0.type == .string }.map { text(python, $0) }, ["'{name}'"])
        // and in shell an apostrophe after a letter still opens a string
        let shell = "echo it's"
        XCTAssertEqual(tokens(shell, "sh").filter { $0.type == .string }.map { text(shell, $0) }, ["'s"])
    }

    func testStringEscapeDoesNotEndEarly() {
        let code = "\"a\\\"b\""              // the literal "a\"b"
        let strings = tokens(code, "swift").filter { $0.type == .string }
        XCTAssertEqual(strings.count, 1)
        XCTAssertEqual(text(code, strings[0]), code)
    }

    func testBlockCommentSpansLines() {
        let code = "/* a\n b */ let"
        let found = tokens(code, "swift")
        XCTAssertTrue(found.contains { $0.type == .comment && text(code, $0) == "/* a\n b */" })
        XCTAssertTrue(found.contains { $0.type == .keyword && text(code, $0) == "let" })
    }

    func testCommentStyleIsLanguageSpecific() {
        let code = "# c\nx = 1"
        XCTAssertTrue(tokens(code, "python").contains { $0.type == .comment && text(code, $0) == "# c" })
        // '#' is not a comment in Swift (which uses //), so the Swift profile finds no comment here.
        XCTAssertFalse(tokens(code, "swift").contains { $0.type == .comment })
    }

    func testNumberDoesNotSwallowRangeOperator() {
        // "0...5" must not be lexed as one number; only "0" and "5" are numbers.
        let code = "for i in 0...5 {}"
        let numbers = tokens(code, "swift").filter { $0.type == .number }.map { text(code, $0) }
        XCTAssertEqual(numbers, ["0", "5"])
    }

    // Outside the Basic Multilingual Plane and with a combining mark, UTF-16 and scalar offsets differ; each
    // range must still name the token's text.
    func testRangesInBothUnitsPastWideCharacters() throws {
        let code = "let s = \"e\u{301}\u{1F600}\" // \u{1F600}x\nlet"
        let found = tokens(code, "swift")
        XCTAssertTrue(found.contains { $0.type == .string && text(code, $0) == "\"e\u{301}\u{1F600}\"" })
        XCTAssertTrue(found.contains { $0.type == .comment && text(code, $0) == "// \u{1F600}x" })
        let last = try XCTUnwrap(found.last)
        XCTAssertEqual(text(code, last), "let")
        XCTAssertEqual(last.utf16Range, (code.utf16.count - 3)..<code.utf16.count)
        XCTAssertEqual(last.scalarRange, (code.unicodeScalars.count - 3)..<code.unicodeScalars.count)
    }

    // The language key is trimmed as trimmingCharacters(in: .whitespaces) trims, which includes U+200B.
    func testLanguageKeyIsTrimmedLikeFoundationsWhitespace() {
        XCTAssertTrue(tokens("let", " swift\u{200B}\t").contains { $0.type == .keyword })
        XCTAssertTrue(tokens("x = 1 # c", "\u{3000}python").contains { $0.type == .comment })
    }

    // MARK: - Applying colors (Apple platforms)

    #if !os(Linux)
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
    #endif
}
