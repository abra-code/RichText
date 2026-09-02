// Tests/RichTextTests/RichTextSearchTests.swift
//
// The find engine (layer 1): matching rules over plain and rendered text, snippets, the plain-text
// linearization for indexers, and the parity guarantee that a headless document search reports the ranges
// the rendered attributed string contains.

import XCTest
@testable import RichText

final class RichTextSearchTests: XCTestCase {

    private func ranges(_ text: String, _ query: String, _ options: RichTextSearchOptions = .default) -> [NSRange] {
        RichTextSearch.matches(in: text, query: query, options: options).map(\.range)
    }

    // MARK: - Matching rules

    func testEmptyOrBlankQueryMatchesNothing() {
        XCTAssertEqual(ranges("anything at all", ""), [])
        XCTAssertEqual(ranges("anything at all", "   "), [])
        XCTAssertEqual(ranges("", "x"), [])
    }

    func testCaseAndDiacriticsAreFoldedByDefault() {
        XCTAssertEqual(ranges("Cafe cafe CAFE", "cafe").count, 3)
        XCTAssertEqual(ranges("resume r\u{e9}sum\u{e9}", "resume").count, 2)
    }

    func testCaseSensitiveOption() {
        let found = ranges("Cafe cafe CAFE", "cafe", RichTextSearchOptions(caseSensitive: true))
        XCTAssertEqual(found, [NSRange(location: 5, length: 4)])
    }

    func testDiacriticSensitiveOption() {
        let found = ranges("resume r\u{e9}sum\u{e9}", "resume", RichTextSearchOptions(diacriticSensitive: true))
        XCTAssertEqual(found, [NSRange(location: 0, length: 6)])
    }

    func testMatchesAreNonOverlappingAndInOrder() {
        // "aaaa" contains "aa" at 0, 1, 2 overlapping; a find bar counts 2 (at 0 and 2).
        XCTAssertEqual(ranges("aaaa", "aa"), [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)])
    }

    func testWholeWordRequiresNonWordNeighbors() {
        let whole = RichTextSearchOptions(wholeWord: true)
        XCTAssertEqual(ranges("cat concatenate cat.", "cat", whole),
                       [NSRange(location: 0, length: 3), NSRange(location: 16, length: 3)])
        XCTAssertEqual(ranges("snake_case case", "case", whole), [NSRange(location: 11, length: 4)])
        XCTAssertEqual(ranges("x1 x", "x", whole), [NSRange(location: 3, length: 1)])
        // A rejected candidate must not swallow the accepted one starting inside it.
        XCTAssertEqual(ranges("kno no no", "no no", whole), [NSRange(location: 4, length: 5)])
        XCTAssertEqual(ranges("no no no", "no no", whole), [NSRange(location: 0, length: 5)])
    }

    func testLimitStopsEarly() {
        XCTAssertEqual(ranges("a a a a", "a", RichTextSearchOptions(limit: 2)).count, 2)
        XCTAssertEqual(ranges("a a a a", "a", RichTextSearchOptions(limit: 0)).count, 0)
    }

    func testUnicodeQueryAndEmojiText() {
        // Emoji are surrogate pairs in UTF-16: the range past one must land on the right unit.
        let text = "\u{1F600} smile \u{1F600}"
        XCTAssertEqual(ranges(text, "smile"), [NSRange(location: 3, length: 5)])
        XCTAssertEqual(ranges(text, "\u{1F600}").count, 2)
    }

    // MARK: - Snippets

    func testSnippetStaysOnTheMatchLineAndCollapsesWhitespace() {
        let text = "first line\nthe   quick brown   fox\nthird line"
        let match = RichTextSearch.matches(in: text, query: "brown").first
        XCTAssertEqual(match?.snippet, "the quick brown fox")
        XCTAssertEqual(match?.rangeInSnippet, NSRange(location: 10, length: 5))
        XCTAssertEqual((match!.snippet as NSString).substring(with: match!.rangeInSnippet), "brown")
    }

    func testSnippetRangeSurvivesLeadingCutAndCollapsedRuns() {
        let text = String(repeating: "y", count: 60) + "   a   needle   b"
        let match = RichTextSearch.matches(in: text, query: "needle", options: RichTextSearchOptions(snippetContext: 10)).first!
        XCTAssertEqual(match.snippet, "...yyy a needle b")
        XCTAssertEqual((match.snippet as NSString).substring(with: match.rangeInSnippet), "needle")
        // A match containing collapsed whitespace keeps its collapsed form inside the snippet.
        let spaced = RichTextSearch.matches(in: "the   quick   fox", query: "quick   fox").first!
        XCTAssertEqual(spaced.snippet, "the quick fox")
        XCTAssertEqual((spaced.snippet as NSString).substring(with: spaced.rangeInSnippet), "quick fox")
    }

    func testSnippetTrimsLongLinesWithEllipses() {
        let filler = String(repeating: "x", count: 100)
        let text = filler + " needle " + filler
        let match = RichTextSearch.matches(in: text, query: "needle").first
        XCTAssertNotNil(match)
        XCTAssertTrue(match!.snippet.hasPrefix("..."), match!.snippet)
        XCTAssertTrue(match!.snippet.hasSuffix("..."), match!.snippet)
        XCTAssertTrue(match!.snippet.contains("needle"))
        XCTAssertLessThan(match!.snippet.count, 2 * RichTextSearchOptions.default.snippetContext + 20)
        XCTAssertEqual((match!.snippet as NSString).substring(with: match!.rangeInSnippet), "needle")
    }

    func testSnippetDropsAttachmentPlaceholders() {
        let text = "see \u{FFFC} the chart"
        let match = RichTextSearch.matches(in: text, query: "chart").first
        XCTAssertEqual(match?.snippet, "see the chart")
    }

    // MARK: - Rendered documents

    func testMatchAcrossInlineRuns() {
        // "un**believ**able": the rendered string is one word, so a query spanning the bold run matches.
        let document = RichTextDocument(markdown: "un**believ**able")
        let found = RichTextSearch.matches(in: document, query: "unbelievable")
        XCTAssertEqual(found.count, 1)
    }

    func testMatchInsideCodeBlockAndTableCell() {
        let markdown = """
        ```swift
        let needle = 1
        ```

        | a | b |
        |---|---|
        | haystack | needle |
        """
        let document = RichTextDocument(markdown: markdown)
        for engine in [RichTextEngine.textKit1, .textKit2] {
            let found = RichTextSearch.matches(in: document, query: "needle", engine: engine)
            XCTAssertEqual(found.count, 2, "\(engine)")
        }
    }

    func testDocumentRangesAreRenderedStringRanges() {
        // Parity: the range a headless search reports is where the text sits in the attributed string the
        // view draws - the whole point of searching the rendered form.
        let document = RichTextDocument(markdown: "# Title\n\nSome *emphasis* here.\n\n- one\n- two")
        let attributed = RichTextAttributedString.make(document, theme: .default, engine: .textKit1)
        for query in ["emphasis", "two", "title"] {
            let found = RichTextSearch.matches(in: document, query: query)
            XCTAssertEqual(found.count, 1, query)
            for match in found {
                let slice = (attributed.string as NSString).substring(with: match.range)
                XCTAssertEqual(slice.lowercased(), query)
            }
        }
    }

    func testImageAltIsNotInRenderedTextButIsInPlainText() {
        let document = RichTextDocument(markdown: "Here ![a napping cat](https://x/c.png) sleeps.")
        // Rendered: the image is an attachment placeholder, so its alt text is not searchable on screen.
        XCTAssertEqual(RichTextSearch.matches(in: document, query: "napping").count, 0)
        // Plain text for an index: the alt text IS what a reader gets from the image.
        XCTAssertTrue(RichTextPlainText.text(for: document).contains("a napping cat"))
    }

    // MARK: - Plain text

    func testPlainTextDropsMarkdownSyntaxAndReadsTablesRowByRow() {
        let markdown = """
        # Heading

        A **bold** word and `code`.

        | h1 | h2 |
        |----|----|
        | c1 | c2 |
        """
        let text = RichTextPlainText.text(for: RichTextDocument(markdown: markdown))
        XCTAssertEqual(text, "Heading\nA bold word and code.\nh1, h2\nc1, c2")
    }
}
