package com.abracode.richtext.rendering

import androidx.compose.ui.graphics.Color
import com.abracode.richtext.model.RichTextBlock
import com.abracode.richtext.model.RichTextDocument
import com.abracode.richtext.model.RichTextInline
import com.abracode.richtext.search.RichTextRange

// The rendered text of a document, and where each drawn text element sits in it.
//
// Apple renders a document into ONE text view, so "the rendered string" exists for free and a search range is an
// offset into it. This renderer draws a Column of per-block composables (plan divergence #1), so the string has
// to be assembled: every Text the block composables draw - a heading, a paragraph, a code block, a table cell,
// each block inside a quote or a list item - is one SEGMENT, in draw order, and the rendered text is the
// segments joined by newlines. A search range in that text maps back to (segment, local range), which is what
// the composable needs to paint it. The walk here and BlockView's dispatch must agree segment for segment; the
// unit tests pin the count per block kind so they cannot drift silently.
//
// What is NOT in the string, and therefore not searchable on screen: list markers (their own Text, outside the
// item's content), thematic breaks, and a paragraph that is only an image (drawn as an image, no Text).
object RichTextRenderedText {

    /** The rendered text and its segments (each a range in [text]), in draw order. */
    class Layout(val text: String, val segments: List<RichTextRange>) {
        /** The local ranges of [ranges] that fall inside segment [index], and which of them is [current]. */
        fun localHighlights(index: Int, highlights: RichTextHighlights?): RichTextLocalHighlights? {
            if (highlights == null || highlights.isEmpty) return null
            val segment = segments.getOrNull(index) ?: return null
            val local = mutableListOf<RichTextRange>()
            var currentLocal: Int? = null
            highlights.ranges.forEachIndexed { i, range ->
                val hit = range.intersect(segment) ?: return@forEachIndexed
                if (i == highlights.current) currentLocal = local.size
                local.add(hit.shifted(-segment.start))
            }
            return if (local.isEmpty()) null else RichTextLocalHighlights(local, currentLocal, highlights.style)
        }
    }

    /** A layout with no text: what a composable that is not being searched carries. */
    val Empty = Layout("", emptyList())

    /** The rendered text for [document]. Colors do not affect the text, so a placeholder palette renders it. */
    fun layout(document: RichTextDocument): Layout {
        val builder = StringBuilder()
        val segments = mutableListOf<RichTextRange>()
        appendBlocks(document.blocks, builder, segments)
        return Layout(builder.toString(), segments)
    }

    /** How many segments [block] draws - the number BlockView's dispatch consumes for it. */
    fun segmentCount(block: RichTextBlock): Int = when (block) {
        is RichTextBlock.Heading -> 1
        is RichTextBlock.Paragraph -> if (block.inlines.soleBlockImage() != null) 0 else 1
        is RichTextBlock.CodeBlock -> 1
        is RichTextBlock.BlockQuote -> block.blocks.sumOf { segmentCount(it) }
        is RichTextBlock.ListBlock -> block.items.sumOf { item -> item.sumOf { segmentCount(it) } }
        RichTextBlock.ThematicBreak -> 0
        is RichTextBlock.Table -> {
            val columns = maxOf(block.headers.size, block.rows.maxOfOrNull { it.size } ?: 0)
            if (columns == 0) 0 else (1 + block.rows.size) * columns
        }
    }

    private fun appendBlocks(blocks: List<RichTextBlock>, out: StringBuilder, segments: MutableList<RichTextRange>) {
        for (block in blocks) appendBlock(block, out, segments)
    }

    private fun appendBlock(block: RichTextBlock, out: StringBuilder, segments: MutableList<RichTextRange>) {
        when (block) {
            is RichTextBlock.Heading -> addSegment(inlineText(block.inlines, bold = true), out, segments)
            is RichTextBlock.Paragraph -> {
                if (block.inlines.soleBlockImage() == null) addSegment(inlineText(block.inlines, bold = false), out, segments)
            }
            is RichTextBlock.CodeBlock -> addSegment(block.code, out, segments)
            is RichTextBlock.BlockQuote -> appendBlocks(block.blocks, out, segments)
            is RichTextBlock.ListBlock -> for (item in block.items) appendBlocks(item, out, segments)
            RichTextBlock.ThematicBreak -> Unit
            is RichTextBlock.Table -> {
                val columns = maxOf(block.headers.size, block.rows.maxOfOrNull { it.size } ?: 0)
                if (columns == 0) return
                val rows = listOf(block.headers to true) + block.rows.map { it to false }
                for ((row, header) in rows) {
                    for (c in 0 until columns) {
                        addSegment(inlineText(row.getOrNull(c) ?: emptyList(), bold = header), out, segments)
                    }
                }
            }
        }
    }

    private fun addSegment(text: String, out: StringBuilder, segments: MutableList<RichTextRange>) {
        if (out.isNotEmpty()) out.append('\n')
        val start = out.length
        out.append(text)
        segments.add(RichTextRange(start, out.length))
    }

    // The same builder the composables use, so the text is byte for byte what they draw (an inline image is its
    // alt text placeholder, a hard break a newline). The colors are irrelevant to the text.
    private fun inlineText(inlines: List<RichTextInline>, bold: Boolean): String =
        buildRichInlines(inlines, placeholderColors, baseColor = Color.Black, initialBold = bold).text.text

    private val placeholderColors = RichTextColors(
        body = Color.Black, secondary = Color.Gray, link = Color.Blue, codeFill = Color.LightGray,
        separator = Color.Gray, keyword = Color.Black, string = Color.Black, number = Color.Black, comment = Color.Black,
    )
}
