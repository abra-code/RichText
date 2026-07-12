package com.abracode.richtext.model

import com.abracode.richtext.markdown.RichTextMarkdownParser

// The cross-platform document model: a tree of blocks and inline runs. This is the single source of truth -
// what the Compose renderer draws and what the serializers (HTML / Markdown) write. It carries NO platform /
// Compose types, so it is testable in isolation on the JVM. A 1:1 port of Sources/RichText/Model/RichTextModel.swift.

/** Per-column alignment for a table. */
enum class RichTextColumnAlignment { NONE, LEFT, CENTER, RIGHT }

/**
 * A block-level element. Arrival-ordered; lists / quotes nest recursively. Mirrors the Swift `RichTextBlock`
 * enum case-for-case (`ListBlock` renames the Swift `.list` case to avoid clashing with `kotlin.collections.List`).
 */
sealed interface RichTextBlock {
    data class Heading(val level: Int, val inlines: List<RichTextInline>) : RichTextBlock
    data class Paragraph(val inlines: List<RichTextInline>) : RichTextBlock
    data class CodeBlock(val language: String?, val code: String) : RichTextBlock
    data class BlockQuote(val blocks: List<RichTextBlock>) : RichTextBlock
    data class ListBlock(
        val ordered: Boolean,
        val start: Int,
        val tight: Boolean,
        val items: List<List<RichTextBlock>>,
    ) : RichTextBlock
    data object ThematicBreak : RichTextBlock
    data class Table(
        val headers: List<List<RichTextInline>>,
        val alignments: List<RichTextColumnAlignment>,
        val rows: List<List<List<RichTextInline>>>,
    ) : RichTextBlock
}

/** An inline run. Emphasis / strong / strikethrough / link nest; `Text` and `Code` are leaves. */
sealed interface RichTextInline {
    data class Text(val value: String) : RichTextInline
    data class Emphasis(val children: List<RichTextInline>) : RichTextInline       // italic
    data class Strong(val children: List<RichTextInline>) : RichTextInline         // bold
    data class Strikethrough(val children: List<RichTextInline>) : RichTextInline
    data class Code(val value: String) : RichTextInline
    data class Link(val text: List<RichTextInline>, val url: String) : RichTextInline
    data class Image(val alt: String, val url: String) : RichTextInline
    data object LineBreak : RichTextInline
}

/** A whole rich-text document: an ordered list of blocks. */
data class RichTextDocument(val blocks: List<RichTextBlock>) {
    companion object {
        /** Builds a document by parsing a Markdown string (the port of Swift's `RichTextDocument(markdown:)`). */
        fun parse(markdown: String): RichTextDocument = RichTextDocument(RichTextMarkdownParser.parse(markdown))
    }
}

// MARK: - Plain-text extraction (used by serializers + table column measuring)

/** The inline runs flattened to plain text (formatting dropped). Port of the Swift `[RichTextInline].plainText`. */
val List<RichTextInline>.plainText: String
    get() {
        val out = StringBuilder()
        for (node in this) {
            when (node) {
                is RichTextInline.Text -> out.append(node.value)
                is RichTextInline.Code -> out.append(node.value)
                RichTextInline.LineBreak -> out.append(" ")
                is RichTextInline.Emphasis -> out.append(node.children.plainText)
                is RichTextInline.Strong -> out.append(node.children.plainText)
                is RichTextInline.Strikethrough -> out.append(node.children.plainText)
                is RichTextInline.Link -> out.append(node.text.plainText)
                is RichTextInline.Image -> out.append(node.alt)
            }
        }
        return out.toString()
    }
