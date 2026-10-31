package com.abracode.richtext

import com.abracode.richtext.model.RichTextBlock
import com.abracode.richtext.model.RichTextDocument
import com.abracode.richtext.model.RichTextInline
import com.abracode.richtext.model.resolvingImageUrls
import org.junit.Assert.assertEquals
import org.junit.Test

// Port of Tests/RichTextTests/RichTextBaseURLTests.swift: relative image paths resolve against the document's own
// location, wherever the image sits in the tree; absolute image URLs and links are left alone.
class RichTextBaseUrlTest {
    private val file = "file:///Users/me/notes/read.md"

    private fun resolved(markdown: String, base: String): List<String> {
        val urls = mutableListOf<String>()
        fun walkInlines(inlines: List<RichTextInline>) {
            for (inline in inlines) {
                when (inline) {
                    is RichTextInline.Image -> urls.add(inline.url)
                    is RichTextInline.Emphasis -> walkInlines(inline.children)
                    is RichTextInline.Strong -> walkInlines(inline.children)
                    is RichTextInline.Strikethrough -> walkInlines(inline.children)
                    is RichTextInline.Link -> walkInlines(inline.text)
                    else -> {}
                }
            }
        }
        fun walkBlocks(blocks: List<RichTextBlock>) {
            for (block in blocks) {
                when (block) {
                    is RichTextBlock.Heading -> walkInlines(block.inlines)
                    is RichTextBlock.Paragraph -> walkInlines(block.inlines)
                    is RichTextBlock.BlockQuote -> walkBlocks(block.blocks)
                    is RichTextBlock.ListBlock -> block.items.forEach { walkBlocks(it) }
                    is RichTextBlock.Table -> {
                        block.headers.forEach { walkInlines(it) }
                        block.rows.forEach { row -> row.forEach { walkInlines(it) } }
                    }
                    else -> {}
                }
            }
        }
        walkBlocks(RichTextDocument.parse(markdown).resolvingImageUrls(base).blocks)
        return urls
    }

    @Test fun relativePathsResolveAgainstTheDocumentsFile() {
        assertEquals(listOf("file:///Users/me/notes/img/a.png"), resolved("![a](img/a.png)", file))
        assertEquals(listOf("file:///Users/me/a.png"), resolved("![a](../a.png)", file))
        assertEquals(listOf("file:///srv/a.png"), resolved("![a](/srv/a.png)", file))
        assertEquals(listOf("file:///Users/me/notes/a.png"), resolved("![a](a.png)", file))
    }

    @Test fun aFolderBaseKeepsItsLastComponent() {
        assertEquals(listOf("file:///Users/me/notes/img/a.png"), resolved("![a](img/a.png)", "file:///Users/me/notes/"))
    }

    @Test fun aWebPageBaseGivesRemoteImages() {
        assertEquals(listOf("https://example.test/docs/img/a.png"),
                     resolved("![a](img/a.png)", "https://example.test/docs/guide.md"))
    }

    @Test fun absoluteUrlsAreLeftAlone() {
        val markdown = "![a](https://x.test/a.png) ![b](data:image/png;base64,AAAA) ![c](file:///tmp/c.png)"
        assertEquals(listOf("https://x.test/a.png", "data:image/png;base64,AAAA", "file:///tmp/c.png"),
                     resolved(markdown, file))
    }

    @Test fun imagesAnywhereInTheTreeResolve() {
        val markdown = """
            # ![h](h.png)

            > - **![q](q.png)** [![l](l.png)](https://x.test)

            | ![t](t.png) |
            | --- |
            | ![r](r.png) |
        """.trimIndent()
        assertEquals(listOf("h", "q", "l", "t", "r").map { "file:///Users/me/notes/$it.png" }, resolved(markdown, file))
    }

    // The same strings as Swift's URL gives (RichTextBaseURLTests): what a URI may not hold is percent-encoded, "?"
    // still starts a query, and ".." stops at the root, where java.net.URI alone would keep it.
    @Test fun encodingQueriesAndTheRoot() {
        assertEquals(listOf("file:///Users/me/notes/my%20pic.png?v=1%202#top"), resolved("![a](<my pic.png?v=1 2#top>)", file))
        assertEquals(listOf("file:///Users/me/notes/caf%C3%A9.png"), resolved("![a](caf\u00e9.png)", file))
        assertEquals(listOf("file:///Users/me/notes/a%7Cb%25zz.png"), resolved("![a](a|b%zz.png)", file))
        assertEquals(listOf("file:///a.png"), resolved("![a](../../../../a.png)", file))
        assertEquals(listOf("https://example.test/a.png"), resolved("![a](../../a.png)", "https://example.test/docs/guide.md"))
    }

    @Test fun linksAndEmptyUrlsAreLeftAlone() {
        val document = RichTextDocument(listOf(RichTextBlock.Paragraph(listOf(
            RichTextInline.Link(listOf(RichTextInline.Text("x")), "other.md"),
            RichTextInline.Image("e", ""),
        ))))
        assertEquals(document, document.resolvingImageUrls(file))
    }
}
