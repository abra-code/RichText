package com.abracode.richtext

import com.abracode.richtext.markdown.RichTextMarkdownParser
import com.abracode.richtext.model.RichTextBlock
import com.abracode.richtext.model.plainText
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random

// The TOTALITY property is what makes re-parse-per-token streaming safe: malformed or INCOMPLETE input never
// throws and never loses visible text. This fuzzes random truncations (and a few mutations) of a corpus
// document, asserting the parser (a) never throws, (b) terminates quickly, and (c) preserves every alphanumeric
// character of prose-only input. Deterministic (seeded RNG) so a failure reproduces.
class RichTextTotalityFuzzTest {

    // Exercises every block/inline feature, including links / images / tables / fenced code whose URL and info
    // strings deliberately do NOT survive into the flattened plain text - used for the no-throw / bounded-time
    // property only.
    private val fullCorpus = """
        # Heading One

        A paragraph with **bold**, *italic*, ***both***, ~~strike~~, `code`, a [link](https://swift.org),
        an autolinked https://example.com, and an ![image](https://x.test/y.png).

        > A block quote
        > > nested deeper

        - item one
          - nested item
        - item two

        1. first
        2. second

        ```swift
        let x = 42  // a comment
        let s = "hello"
        ```

        | Feature | Status |
        | :-- | :-: |
        | Tables | ok |

        ---

        [ref]: https://swift.org
        A [shortcut][ref] reference.
    """.trimIndent()

    // Prose + inline markup + unordered lists + quotes only: no links, images, tables, fenced-code info strings,
    // pipes, or ORDERED lists, so every alphanumeric character is "content" that must survive parsing. (URL /
    // info-string / alt-text characters, and an ordered list's marker digit - which the renderer regenerates
    // from `start` rather than storing as text - do not appear in the flattened plainText, so they are excluded.)
    private val proseCorpus = """
        # A Prose Heading

        The quick brown fox jumps over the lazy dog. This has **bold words**, *italic words*,
        ~~struck words~~, and some `inline code` too. Numbers like 42 and 1234 appear here.

        A second paragraph continues with more text, a hard break here
        and then a continuation line that folds together.

        > A quoted line with emphasis and 7 sevens.
        > > Deeper quoting still keeps every letter.

        - alpha
          - beta gamma
        - delta 99
        - epsilon zeta
    """.trimIndent()

    private fun flatten(blocks: List<RichTextBlock>): String {
        val out = StringBuilder()
        for (block in blocks) {
            when (block) {
                is RichTextBlock.Heading -> out.append(block.inlines.plainText)
                is RichTextBlock.Paragraph -> out.append(block.inlines.plainText)
                is RichTextBlock.CodeBlock -> out.append(block.code)
                is RichTextBlock.BlockQuote -> out.append(flatten(block.blocks))
                is RichTextBlock.ListBlock -> block.items.forEach { out.append(flatten(it)) }
                RichTextBlock.ThematicBreak -> {}
                is RichTextBlock.Table -> {
                    out.append(block.headers.joinToString("") { it.plainText })
                    block.rows.forEach { row -> out.append(row.joinToString("") { it.plainText }) }
                }
            }
        }
        return out.toString()
    }

    private fun alphanumerics(s: String): String = s.filter { it.isLetterOrDigit() }

    @Test fun randomTruncationsNeverThrowAndTerminateQuickly() {
        val random = Random(20260711L)
        for (iteration in 0 until 2000) {
            val cut = random.nextInt(fullCorpus.length + 1)
            val prefix = fullCorpus.substring(0, cut)
            val start = System.nanoTime()
            RichTextMarkdownParser.parse(prefix)               // must not throw
            val elapsedMs = (System.nanoTime() - start) / 1_000_000
            assertTrue("truncation of length $cut parsed too slowly ($elapsedMs ms)", elapsedMs < 2000)
        }
    }

    @Test fun randomTruncationsPreserveEveryVisibleCharacterOfProse() {
        for (cut in 0..proseCorpus.length) {
            val prefix = proseCorpus.substring(0, cut)
            val blocks = RichTextMarkdownParser.parse(prefix)  // must not throw
            assertEquals(
                "visible text lost at truncation length $cut",
                alphanumerics(prefix),
                alphanumerics(flatten(blocks)),
            )
        }
    }

    @Test fun randomSingleCharacterMutationsNeverThrow() {
        val random = Random(424242L)
        val chars = fullCorpus.toCharArray()
        // Includes URL-forming characters (h t t p : / . w) so mutations can synthesize http:// and www.
        // fragments and exercise the autolinker's scan/trim paths, not just the structural delimiters.
        val palette = "*_~`[]()#|->\\ \nhtp:/.w".toCharArray()
        for (iteration in 0 until 2000) {
            val copy = chars.copyOf()
            val edits = 1 + random.nextInt(8)
            repeat(edits) {
                copy[random.nextInt(copy.size)] = palette[random.nextInt(palette.size)]
            }
            RichTextMarkdownParser.parse(String(copy))         // must not throw
        }
    }

    @Test fun autolinkerHandlesAdversarialUrlsInLinearTime() {
        // A bare URL whose body is a long run of trailing closing brackets, or a very long host, must not push
        // the autolinker's consume/trim into superlinear time - it is reached from untrusted, re-parsed-per-token
        // text just like the rest of the parser.
        val cases = listOf(
            "http://" + ")".repeat(200_000),                 // trailing-bracket run (the O(n^2) trap)
            "www." + "]".repeat(200_000),                    // same via the www. branch
            "see http://" + "a".repeat(200_000) + " end",    // one very long linked host
            "http://a.io). ".repeat(50_000),                 // many real links with trailing punctuation
        )
        for (case in cases) {
            val start = System.nanoTime()
            RichTextMarkdownParser.parse(case)               // must not throw
            val elapsedMs = (System.nanoTime() - start) / 1_000_000
            assertTrue("autolinker went superlinear on a ${case.length}-char input ($elapsedMs ms)", elapsedMs < 2000)
        }
    }

    @Test fun headingWithHugeInteriorWhitespaceStaysTotal() {
        // A heading line with a long interior whitespace run and no trailing '#' must not push the closing-hash
        // stripper into catastrophic backtracking (a naive Regex("\\s+#+\\s*$") would). Also check the case that
        // DOES have a trailing hash sequence to buried in whitespace.
        val cases = listOf(
            "# a" + " ".repeat(200_000) + "b",              // no '#': the O(n^2) regex trap
            "# title" + " ".repeat(200_000) + "###",        // real closing sequence after a long gap
            "#" + " ".repeat(200_000) + "#",
        )
        for (case in cases) {
            val start = System.nanoTime()
            val blocks = RichTextMarkdownParser.parse(case)   // must not throw
            val elapsedMs = (System.nanoTime() - start) / 1_000_000
            assertTrue("heading closing-hash strip went superlinear (${case.length} chars, $elapsedMs ms)", elapsedMs < 2000)
            assertTrue(blocks.first() is RichTextBlock.Heading)
        }
    }

    @Test fun hugeOrderedListMarkerStaysTotal() {
        // A list marker beyond 32-bit range: the Swift reference (64-bit Int) preserves it, while this port's
        // 32-bit `start` falls back to 1 (a documented micro-limitation on an unrealistic input). Either way the
        // parse must stay TOTAL - never throw, never lose the item text.
        val blocks = RichTextMarkdownParser.parse("2147483648. item text")
        assertTrue(blocks.first() is RichTextBlock.ListBlock)
        assertTrue("item text must survive", flatten(blocks).contains("item text"))
    }
}
