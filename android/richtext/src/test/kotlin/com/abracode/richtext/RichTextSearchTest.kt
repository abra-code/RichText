package com.abracode.richtext

import com.abracode.richtext.model.RichTextBlock
import com.abracode.richtext.model.RichTextDocument
import com.abracode.richtext.model.RichTextInline
import com.abracode.richtext.rendering.RichTextRenderedText
import com.abracode.richtext.search.RichTextPlainText
import com.abracode.richtext.search.RichTextRange
import com.abracode.richtext.search.RichTextSearch
import com.abracode.richtext.search.RichTextSearchOptions
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

// Port of Tests/RichTextTests/RichTextSearchTests.swift: the find engine's matching rules over plain and rendered
// text, snippets, the plain-text linearization for indexers, and the parity guarantee that a headless document
// search reports ranges into the text the composables draw (RichTextRenderedText).
class RichTextSearchTest {

    private fun ranges(text: String, query: String, options: RichTextSearchOptions = RichTextSearchOptions.Default) =
        RichTextSearch.ranges(text, query, options)

    private fun r(start: Int, end: Int) = RichTextRange(start, end)

    // --- Matching rules. ---

    @Test fun emptyOrBlankQueryMatchesNothing() {
        assertEquals(emptyList<RichTextRange>(), ranges("anything at all", ""))
        assertEquals(emptyList<RichTextRange>(), ranges("anything at all", "   "))
        assertEquals(emptyList<RichTextRange>(), ranges("", "x"))
    }

    @Test fun caseAndDiacriticsAreFoldedByDefault() {
        assertEquals(3, ranges("Cafe cafe CAFE", "cafe").size)
        assertEquals(2, ranges("resume r\u00e9sum\u00e9", "resume").size)
        // The folded match still reports the ORIGINAL offsets, accented letters and all.
        assertEquals(listOf(r(0, 6), r(7, 13)), ranges("resume r\u00e9sum\u00e9", "resume"))
    }

    @Test fun caseSensitiveOption() {
        assertEquals(listOf(r(5, 9)), ranges("Cafe cafe CAFE", "cafe", RichTextSearchOptions(caseSensitive = true)))
    }

    @Test fun decomposedAccentsFoldLikePrecomposedOnes() {
        // NFD text (a base letter plus a combining mark) is what macOS and some agents emit: it must match the
        // same queries as NFC, and the reported range must cover the mark.
        assertEquals(listOf(r(0, 8), r(9, 17)), ranges("re\u0301sume\u0301 re\u0301sume\u0301", "resume"))
        assertEquals(listOf(r(0, 5)), ranges("cafe\u0301 x", "cafe"))
        assertEquals(listOf(r(0, 7)), ranges("cafe\u0301 x", "cafe x"))
        assertEquals(listOf(r(0, 4)), ranges("caf\u00e9", "cafe\u0301"))
        assertEquals("a query of nothing but a mark finds nothing", emptyList<RichTextRange>(), ranges("caf\u00e9", "\u0301"))
    }

    @Test fun snippetOfAMatchCrossingANewlineKeepsTheWholeMatch() {
        val text = "say world\nhello there"
        val match = RichTextSearch.matches(text, "world\nhello").first()
        assertEquals("world\nhello", text.substring(match.range.start, match.range.end))
        assertEquals("world hello", match.snippet.substring(match.rangeInSnippet.start, match.rangeInSnippet.end))
        val leading = RichTextSearch.matches("\nabc", "abc").first()
        assertEquals(r(0, 3), leading.rangeInSnippet)
    }

    @Test fun nestedBlocksCountTheirSegmentsLikeTheComposables() {
        val markdown = "> quote\n>\n> - a\n> - b\n>   - c\n\n| h1 | h2 | h3 |\n|---|---|---|\n| x |\n"
        val document = RichTextDocument.parse(markdown)
        val layout = RichTextRenderedText.layout(document)
        assertEquals(layout.segments.size, document.blocks.sumOf { RichTextRenderedText.segmentCount(it) })
        // The quote holds a paragraph and a list of two items, the second nesting one more: 4 texts.
        assertEquals(4, RichTextRenderedText.segmentCount(document.blocks[0]))
        // A ragged table still draws every cell of every row: (1 + 1) rows x 3 columns.
        assertEquals(6, RichTextRenderedText.segmentCount(document.blocks[1]))
    }

    @Test fun diacriticSensitiveOption() {
        assertEquals(listOf(r(0, 6)), ranges("resume r\u00e9sum\u00e9", "resume", RichTextSearchOptions(diacriticSensitive = true)))
    }

    @Test fun matchesAreNonOverlappingAndInOrder() {
        assertEquals(listOf(r(0, 2), r(2, 4)), ranges("aaaa", "aa"))
    }

    @Test fun wholeWordRequiresNonWordNeighbors() {
        val whole = RichTextSearchOptions(wholeWord = true)
        assertEquals(listOf(r(0, 3), r(16, 19)), ranges("cat concatenate cat.", "cat", whole))
        assertEquals(listOf(r(11, 15)), ranges("snake_case case", "case", whole))
        assertEquals(listOf(r(3, 4)), ranges("x1 x", "x", whole))
        // A rejected candidate must not swallow the accepted one starting inside it.
        assertEquals(listOf(r(4, 9)), ranges("kno no no", "no no", whole))
        assertEquals(listOf(r(0, 5)), ranges("no no no", "no no", whole))
    }

    @Test fun limitStopsEarly() {
        assertEquals(2, ranges("a a a a", "a", RichTextSearchOptions(limit = 2)).size)
        assertEquals(0, ranges("a a a a", "a", RichTextSearchOptions(limit = 0)).size)
    }

    @Test fun unicodeQueryAndEmojiText() {
        // Emoji are surrogate pairs in UTF-16: the range past one must land on the right unit.
        val smile = String(Character.toChars(0x1F600))
        val text = "$smile smile $smile"
        assertEquals(listOf(r(3, 8)), ranges(text, "smile"))
        assertEquals(2, ranges(text, smile).size)
    }

    // --- Snippets. ---

    @Test fun snippetStaysOnTheMatchLineAndCollapsesWhitespace() {
        val match = RichTextSearch.matches("first line\nthe   quick brown   fox\nthird line", "brown").first()
        assertEquals("the quick brown fox", match.snippet)
        assertEquals(r(10, 15), match.rangeInSnippet)
        assertEquals("brown", match.snippet.substring(match.rangeInSnippet.start, match.rangeInSnippet.end))
    }

    @Test fun snippetTrimsLongLinesWithEllipses() {
        val filler = "x".repeat(100)
        val match = RichTextSearch.matches("$filler needle $filler", "needle").first()
        assertTrue(match.snippet, match.snippet.startsWith("..."))
        assertTrue(match.snippet, match.snippet.endsWith("..."))
        assertEquals("needle", match.snippet.substring(match.rangeInSnippet.start, match.rangeInSnippet.end))
        assertTrue(match.snippet.length < 2 * RichTextSearchOptions.Default.snippetContext + 20)
    }

    @Test fun snippetRangeSurvivesLeadingCutAndCollapsedRuns() {
        val text = "y".repeat(60) + "   a   needle   b"
        val match = RichTextSearch.matches(text, "needle", RichTextSearchOptions(snippetContext = 10)).first()
        assertEquals("...yyy a needle b", match.snippet)
        assertEquals("needle", match.snippet.substring(match.rangeInSnippet.start, match.rangeInSnippet.end))
        val spaced = RichTextSearch.matches("the   quick   fox", "quick   fox").first()
        assertEquals("the quick fox", spaced.snippet)
        assertEquals("quick fox", spaced.snippet.substring(spaced.rangeInSnippet.start, spaced.rangeInSnippet.end))
    }

    @Test fun snippetDropsAttachmentPlaceholders() {
        val match = RichTextSearch.matches("see \uFFFC the chart", "chart").first()
        assertEquals("see the chart", match.snippet)
    }

    // --- Rendered documents. ---

    @Test fun matchAcrossInlineRuns() {
        // "un**believ**able": the rendered text is one word, so a query spanning the bold run matches.
        assertEquals(1, RichTextSearch.matches(RichTextDocument.parse("un**believ**able"), "unbelievable").size)
    }

    @Test fun matchInsideCodeBlockAndTableCell() {
        val markdown = "```swift\nlet needle = 1\n```\n\n| a | b |\n|---|---|\n| haystack | needle |\n"
        assertEquals(2, RichTextSearch.matches(RichTextDocument.parse(markdown), "needle").size)
    }

    @Test fun documentRangesAreRenderedTextRanges() {
        // Parity: the range a headless search reports is where the text sits in what the composables draw.
        val document = RichTextDocument.parse("# Title\n\nSome *emphasis* here.\n\n- one\n- two")
        val rendered = RichTextRenderedText.layout(document).text
        for (query in listOf("emphasis", "two", "title")) {
            val found = RichTextSearch.matches(document, query)
            assertEquals(query, 1, found.size)
            assertEquals(query, rendered.substring(found[0].range.start, found[0].range.end).lowercase())
        }
    }

    @Test fun imageAltIsInRenderedTextAsPlaceholderAndInPlainText() {
        // The Compose inline image placeholder carries the alt text (unlike Apple's U+FFFC), so it is searchable
        // on screen here; the plain text for an index has it either way.
        val document = RichTextDocument.parse("Here ![a napping cat](https://x/c.png) sleeps.")
        assertEquals(1, RichTextSearch.matches(document, "napping").size)
        assertTrue(RichTextPlainText.text(document).contains("a napping cat"))
    }

    // --- Plain text. ---

    @Test fun plainTextDropsMarkdownSyntaxAndReadsTablesRowByRow() {
        val markdown = "# Heading\n\nA **bold** word and `code`.\n\n| h1 | h2 |\n|----|----|\n| c1 | c2 |\n"
        assertEquals("Heading\nA bold word and code.\nh1, h2\nc1, c2", RichTextPlainText.text(RichTextDocument.parse(markdown)))
    }

    @Test fun plainTextSpeaksImageAltAndSkipsDecorativeImages() {
        assertTrue(RichTextPlainText.text(RichTextDocument.parse("![a napping cat](https://x/c.png)")).contains("a napping cat"))
        assertEquals("", RichTextPlainText.text(RichTextDocument.parse("![](https://x/c.png)")))
    }

    // --- The rendered-text layout: one segment per drawn Text, in draw order. ---

    @Test fun segmentsMirrorTheDrawnTexts() {
        val markdown = "# H\n\npara\n\n---\n\n> quoted\n\n- one\n- two\n\n```\ncode\n```\n\n| a | b |\n|---|---|\n| c | d |\n\n![only](https://x/i.png)\n"
        val document = RichTextDocument.parse(markdown)
        val layout = RichTextRenderedText.layout(document)
        val perBlock = document.blocks.map { RichTextRenderedText.segmentCount(it) }
        // heading, paragraph, rule (0), quote (1), list (2), code (1), table (2 rows x 2 cells), image paragraph (0)
        assertEquals(listOf(1, 1, 0, 1, 2, 1, 4, 0), perBlock)
        assertEquals(perBlock.sum(), layout.segments.size)
        assertEquals("H\npara\nquoted\none\ntwo\ncode\na\nb\nc\nd", layout.text)
        for ((i, segment) in layout.segments.withIndex()) {
            assertTrue("segment $i within text", segment.end <= layout.text.length)
            if (i > 0) assertEquals("segments are separated by one newline", layout.segments[i - 1].end + 1, segment.start)
        }
    }

    @Test fun localHighlightsAreCutToTheirSegment() {
        val document = RichTextDocument(
            listOf(
                RichTextBlock.Paragraph(listOf(RichTextInline.Text("fox one"))),
                RichTextBlock.Paragraph(listOf(RichTextInline.Text("fox two"))),
            ),
        )
        val layout = RichTextRenderedText.layout(document)
        val hits = RichTextSearch.ranges(layout.text, "fox")
        assertEquals(listOf(r(0, 3), r(8, 11)), hits)
        val highlights = com.abracode.richtext.rendering.RichTextHighlights(hits, current = 1)
        val first = layout.localHighlights(0, highlights)!!
        assertEquals(listOf(r(0, 3)), first.ranges)
        assertEquals(null, first.current)
        val second = layout.localHighlights(1, highlights)!!
        assertEquals(listOf(r(0, 3)), second.ranges)
        assertEquals(0, second.current)
    }
}
