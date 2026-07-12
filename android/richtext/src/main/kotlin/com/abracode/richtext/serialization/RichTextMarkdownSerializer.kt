package com.abracode.richtext.serialization

import com.abracode.richtext.model.RichTextBlock
import com.abracode.richtext.model.RichTextColumnAlignment
import com.abracode.richtext.model.RichTextDocument
import com.abracode.richtext.model.RichTextInline

// Model -> Markdown. The inverse of the parser; used for plain round-trip on the clipboard. A 1:1 port of
// Sources/RichText/Serialization/RichTextMarkdownSerializer.swift.

object RichTextMarkdownSerializer {

    fun string(document: RichTextDocument): String = blocks(document.blocks, "")

    private fun blocks(blocks: List<RichTextBlock>, indent: String): String =
        blocks.joinToString("\n\n") { block(it, indent) }

    private fun block(block: RichTextBlock, indent: String): String = when (block) {
        is RichTextBlock.Heading ->
            "#".repeat(block.level) + " " + inline(block.inlines)
        is RichTextBlock.Paragraph ->
            inline(block.inlines)
        is RichTextBlock.CodeBlock ->
            "```" + (block.language ?: "") + "\n" + block.code + "\n```"
        is RichTextBlock.BlockQuote ->
            blocks(block.blocks, "").split("\n").joinToString("\n") { "> $it" }
        is RichTextBlock.ListBlock ->
            list(block.ordered, block.start, block.items, indent)
        RichTextBlock.ThematicBreak ->
            "---"
        is RichTextBlock.Table ->
            table(block.headers, block.alignments, block.rows)
    }

    private fun list(ordered: Boolean, start: Int, items: List<List<RichTextBlock>>, indent: String): String {
        val lines = mutableListOf<String>()
        for ((offset, itemBlocks) in items.withIndex()) {
            val marker = if (ordered) "${start + offset}. " else "- "
            val rendered = blocks(itemBlocks, indent + "  ")
            val parts = rendered.split("\n")
            for ((lineIndex, part) in parts.withIndex()) {
                if (lineIndex == 0) {
                    lines.add(indent + marker + part)
                } else {
                    lines.add(indent + "  " + part)
                }
            }
        }
        return lines.joinToString("\n")
    }

    private fun table(
        headers: List<List<RichTextInline>>,
        alignments: List<RichTextColumnAlignment>,
        rows: List<List<List<RichTextInline>>>,
    ): String {
        val columns = maxOf(headers.size, rows.maxOfOrNull { it.size } ?: 0)
        fun cell(cells: List<List<RichTextInline>>, c: Int): String = if (c < cells.size) inline(cells[c]) else ""
        fun delimiter(c: Int): String {
            val a = if (c < alignments.size) alignments[c] else RichTextColumnAlignment.NONE
            return when (a) {
                RichTextColumnAlignment.LEFT -> ":---"
                RichTextColumnAlignment.CENTER -> ":---:"
                RichTextColumnAlignment.RIGHT -> "---:"
                RichTextColumnAlignment.NONE -> "---"
            }
        }
        val lines = mutableListOf<String>()
        lines.add("| " + (0 until columns).joinToString(" | ") { cell(headers, it) } + " |")
        lines.add("| " + (0 until columns).joinToString(" | ") { delimiter(it) } + " |")
        for (row in rows) {
            lines.add("| " + (0 until columns).joinToString(" | ") { cell(row, it) } + " |")
        }
        return lines.joinToString("\n")
    }

    fun inline(nodes: List<RichTextInline>): String {
        val out = StringBuilder()
        for (node in nodes) {
            when (node) {
                is RichTextInline.Text -> out.append(node.value)
                is RichTextInline.Emphasis -> out.append("*").append(inline(node.children)).append("*")
                is RichTextInline.Strong -> out.append("**").append(inline(node.children)).append("**")
                is RichTextInline.Strikethrough -> out.append("~~").append(inline(node.children)).append("~~")
                is RichTextInline.Code -> out.append("`").append(node.value).append("`")
                is RichTextInline.Link -> out.append("[").append(inline(node.text)).append("](").append(node.url).append(")")
                is RichTextInline.Image -> out.append("![").append(node.alt).append("](").append(node.url).append(")")
                RichTextInline.LineBreak -> out.append("  \n")
            }
        }
        return out.toString()
    }
}
