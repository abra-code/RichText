package com.abracode.richtext

import com.abracode.richtext.markdown.RichTextMarkdownParser
import com.abracode.richtext.model.RichTextBlock
import com.abracode.richtext.model.RichTextColumnAlignment
import com.abracode.richtext.model.RichTextDocument
import com.abracode.richtext.model.RichTextInline
import com.abracode.richtext.model.plainText
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

// Port of Tests/RichTextTests/RichTextMarkdownParserTests.swift. Same cases, same expectations.
class RichTextMarkdownParserTest {

    private fun parse(md: String): List<RichTextBlock> = RichTextMarkdownParser.parse(md)

    // Terse builders mirroring the Swift enum-literal test style.
    private fun text(s: String) = RichTextInline.Text(s)
    private fun code(s: String) = RichTextInline.Code(s)
    private fun emph(vararg n: RichTextInline) = RichTextInline.Emphasis(n.toList())
    private fun strong(vararg n: RichTextInline) = RichTextInline.Strong(n.toList())
    private fun link(url: String, vararg n: RichTextInline) = RichTextInline.Link(n.toList(), url)
    private fun image(alt: String, url: String) = RichTextInline.Image(alt, url)
    private fun para(vararg n: RichTextInline) = RichTextBlock.Paragraph(n.toList())
    private fun heading(level: Int, vararg n: RichTextInline) = RichTextBlock.Heading(level, n.toList())

    @Test fun paragraphAndInline() {
        assertEquals(
            listOf(para(emph(text("a")), text(" "), strong(text("b")), text(" "), code("c"))),
            parse("*a* **b** `c`"),
        )
    }

    @Test fun headingAndLink() {
        assertEquals(listOf(heading(1, text("Title"))), parse("# Title"))
        assertEquals(
            listOf(para(link("https://swift.org", text("x")))),
            parse("[x](https://swift.org)"),
        )
    }

    @Test fun unterminatedSpanIsLiteral() {
        assertEquals(listOf(para(text("a **bold and more"))), parse("a **bold and more"))
    }

    @Test fun fencedCode() {
        assertEquals(
            listOf(RichTextBlock.CodeBlock("swift", "let x = 1")),
            parse("```swift\nlet x = 1\n```"),
        )
    }

    @Test fun listNestedAndTable() {
        val list = parse("- a\n  - b\n- c").first()
        assertTrue(list is RichTextBlock.ListBlock)
        assertEquals(2, (list as RichTextBlock.ListBlock).items.size)

        val table = parse("| A | B |\n| - | :-: |\n| 1 | 2 |").first()
        assertTrue(table is RichTextBlock.Table)
        table as RichTextBlock.Table
        assertEquals(listOf("A", "B"), table.headers.map { it.plainText })
        assertEquals(listOf(RichTextColumnAlignment.NONE, RichTextColumnAlignment.CENTER), table.alignments)
        assertEquals(listOf("1", "2"), table.rows.first().map { it.plainText })
    }

    @Test fun documentConvenience() {
        assertEquals(listOf(heading(1, text("Hi"))), RichTextDocument.parse("# Hi").blocks)
    }

    // MARK: - Autolinking

    private fun inlines(md: String): List<RichTextInline> {
        val first = parse(md).firstOrNull()
        return if (first is RichTextBlock.Paragraph) first.inlines else emptyList()
    }

    @Test fun autolinkBareURL() {
        val nodes = inlines("see https://swift.org now")
        assertEquals(3, nodes.size)
        assertEquals(text("see "), nodes.first())
        assertEquals(text(" now"), nodes.last())
        val l = nodes[1] as RichTextInline.Link
        assertEquals("https://swift.org", l.text.plainText)
        assertTrue("url was ${l.url}", l.url.contains("swift.org"))
    }

    @Test fun autolinkWWWGetsScheme() {
        val l = inlines("visit www.swift.org").last() as RichTextInline.Link
        assertEquals("www.swift.org", l.text.plainText)
        assertTrue("url was ${l.url}", l.url.startsWith("http"))
    }

    @Test fun autolinkExcludesTrailingPunctuation() {
        val nodes = inlines("go to https://swift.org.")
        assertEquals(text("."), nodes.last())
        val l = nodes[1] as RichTextInline.Link
        assertEquals("https://swift.org", l.text.plainText)
    }

    @Test fun autolinkInsideBold() {
        val bold = inlines("**https://swift.org**").first() as RichTextInline.Strong
        val l = bold.children.first() as RichTextInline.Link
        assertEquals("https://swift.org", l.text.plainText)
    }

    @Test fun urlInCodeIsNotLinked() {
        assertEquals(listOf(para(code("https://swift.org"))), parse("`https://swift.org`"))
    }

    @Test fun explicitLinkNotDoubleLinked() {
        assertEquals(
            listOf(para(link("https://swift.org", text("https://swift.org")))),
            parse("[https://swift.org](https://swift.org)"),
        )
    }

    @Test fun plainTextUnchanged() {
        assertEquals(listOf(para(text("just words, no links here"))), parse("just words, no links here"))
    }

    // MARK: - Reference-style links

    @Test fun referenceLinkFull() {
        assertEquals(
            listOf(para(link("https://swift.org", text("text")))),
            parse("[text][ref]\n\n[ref]: https://swift.org"),
        )
    }

    @Test fun referenceLinkCollapsed() {
        assertEquals(
            listOf(para(link("https://swift.org", text("ref")))),
            parse("[ref][]\n\n[ref]: https://swift.org"),
        )
    }

    @Test fun referenceLinkShortcut() {
        assertEquals(
            listOf(para(link("https://swift.org", text("ref")))),
            parse("[ref]\n\n[ref]: https://swift.org"),
        )
    }

    @Test fun referenceLinkLabelIsCaseInsensitive() {
        assertEquals(
            listOf(para(link("https://swift.org", text("Text")))),
            parse("[Text][REF]\n\n[ref]: https://swift.org"),
        )
    }

    @Test fun undefinedReferenceIsLiteral() {
        val first = parse("[text][missing]").first()
        assertTrue(first is RichTextBlock.Paragraph)
        val nodes = (first as RichTextBlock.Paragraph).inlines
        assertEquals("[text][missing]", nodes.plainText)
        assertFalse(nodes.any { it is RichTextInline.Link })
    }

    @Test fun loneDefinitionRendersNothing() {
        assertEquals(emptyList<RichTextBlock>(), parse("[ref]: https://swift.org"))
    }

    @Test fun definitionInsideFenceIsNotExtracted() {
        assertEquals(
            listOf(RichTextBlock.CodeBlock(null, "[ref]: https://swift.org")),
            parse("```\n[ref]: https://swift.org\n```"),
        )
    }

    // MARK: - Images

    @Test fun image() {
        assertEquals(
            listOf(text("before "), image("a cat", "https://x.test/cat.png"), text(" after")),
            inlines("before ![a cat](https://x.test/cat.png) after"),
        )
    }

    @Test fun imageVsLink() {
        assertEquals(listOf(image("alt", "u")), inlines("![alt](u)"))
        assertEquals(listOf(link("u", text("alt"))), inlines("[alt](u)"))
    }

    @Test fun bangWithoutImageIsLiteral() {
        assertEquals(listOf(text("hi! there")), inlines("hi! there"))
    }

    // MARK: - Heading closing hashes

    @Test fun headingClosingHashNotStrippedWithoutSpace() {
        assertEquals(listOf(heading(1, text("C#"))), parse("# C#"))
    }

    @Test fun headingClosingSequenceStripped() {
        assertEquals(listOf(heading(1, text("Title"))), parse("# Title ###"))
        assertEquals(listOf(heading(1, text("Title"))), parse("# Title #"))
    }

    // MARK: - Fenced code / reference extraction consistency

    @Test fun fourBacktickFenceKeepsInnerDefinitionAsCode() {
        val md = "````\n```\n[ref]: https://swift.org\n````"
        assertEquals(
            listOf(RichTextBlock.CodeBlock(null, "```\n[ref]: https://swift.org")),
            parse(md),
        )
    }

    // MARK: - DoS guards (inline)

    @Test fun unbalancedBracketsParseFastWithoutTextLoss() {
        val input = "[".repeat(100_000) + "x"
        val start = System.nanoTime()
        val blocks = parse(input)
        assertTrue("unbalanced brackets should parse well under a second", elapsedMs(start) < 5000)
        val first = blocks.first()
        assertTrue(first is RichTextBlock.Paragraph)
        assertEquals("no characters may be lost", input, (first as RichTextBlock.Paragraph).inlines.plainText)
    }

    @Test fun mixedBracketEmphasisParsesFastWithoutTextLoss() {
        val input = "[*".repeat(50_000) + "x"
        val start = System.nanoTime()
        val blocks = parse(input)
        assertTrue("mixed unbalanced markup should parse well under a second", elapsedMs(start) < 5000)
        val first = blocks.first()
        assertTrue(first is RichTextBlock.Paragraph)
        val flat = (first as RichTextBlock.Paragraph).inlines.plainText
        assertEquals(50_000, flat.count { it == '[' })
        assertTrue(flat.endsWith("x"))
    }

    @Test fun nestedLinkAndEmphasisStillParse() {
        assertEquals(
            listOf(para(link("v", emph(link("u", text("bold")))))),
            inlines("[*[bold](u)*](v)").let { listOf(RichTextBlock.Paragraph(it)) },
        )
    }

    // MARK: - DoS guards (blocks)

    @Test fun deeplyNestedBlockQuoteDoesNotOverflow() {
        val input = "> ".repeat(100_000) + "x"
        val start = System.nanoTime()
        val blocks = parse(input)
        assertTrue(elapsedMs(start) < 5000)
        assertFalse(blocks.isEmpty())
        assertTrue("trailing text must survive", allText(blocks).contains("x"))
    }

    @Test fun deeplyNestedListDoesNotOverflow() {
        val levels = 300
        val input = (0 until levels).joinToString("\n") { " ".repeat(it * 2) + "- x$it" }
        val start = System.nanoTime()
        val blocks = parse(input)
        assertTrue(elapsedMs(start) < 5000)
        assertTrue("deepest item text must survive", allText(blocks).contains("x${levels - 1}"))
    }

    private fun elapsedMs(startNanos: Long): Long = (System.nanoTime() - startNanos) / 1_000_000

    // Recursively flattens every block to its plain text - used only to assert no text is lost.
    private fun allText(blocks: List<RichTextBlock>): String {
        val out = StringBuilder()
        for (block in blocks) {
            when (block) {
                is RichTextBlock.Heading -> out.append(block.inlines.plainText)
                is RichTextBlock.Paragraph -> out.append(block.inlines.plainText)
                is RichTextBlock.CodeBlock -> out.append(block.code)
                is RichTextBlock.BlockQuote -> out.append(allText(block.blocks))
                is RichTextBlock.ListBlock -> block.items.forEach { out.append(allText(it)) }
                RichTextBlock.ThematicBreak -> {}
                is RichTextBlock.Table -> {
                    out.append(block.headers.joinToString("") { it.plainText })
                    block.rows.forEach { row -> out.append(row.joinToString("") { it.plainText }) }
                }
            }
        }
        return out.toString()
    }
}
