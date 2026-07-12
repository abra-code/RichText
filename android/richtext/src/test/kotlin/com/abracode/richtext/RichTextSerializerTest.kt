package com.abracode.richtext

import com.abracode.richtext.model.RichTextBlock
import com.abracode.richtext.model.RichTextDocument
import com.abracode.richtext.model.RichTextInline
import com.abracode.richtext.serialization.RichTextHTMLSerializer
import com.abracode.richtext.serialization.RichTextImageFormat
import com.abracode.richtext.serialization.RichTextImageResolver
import com.abracode.richtext.serialization.RichTextInlineImage
import com.abracode.richtext.serialization.RichTextMarkdownSerializer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

// Port of the HTML + Markdown cases from Tests/RichTextTests/RichTextSerializerTests.swift. The RTF cases are
// out of scope (section 8: no RTF serializer on Android).
class RichTextSerializerTest {

    private val richDoc = RichTextDocument.parse(
        """
        # Title

        Para with **bold**, *italic*, `code`, and [link](https://swift.org).

        > a quote

        ```swift
        let x = 1
        ```

        | Feature | Status |
        | --- | :-: |
        | Code | ok |

        ---
        """.trimIndent(),
    )

    private fun base64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)

    // The Markdown serializer is the parser's inverse for the supported subset.
    @Test fun markdownRoundTripStable() {
        val simple = RichTextDocument.parse("# Hi\n\nA **b** and `c`.\n\n| A | B |\n| --- | ---: |\n| 1 | 2 |")
        val reparsed = RichTextDocument.parse(RichTextMarkdownSerializer.string(simple))
        assertEquals(simple, reparsed)
    }

    @Test fun htmlContainsBlocksAndInline() {
        val html = RichTextHTMLSerializer.fragment(richDoc)
        for (needle in listOf(
            "<h1", "<strong>", "<em>", "<code", "<a href=\"https://swift.org\"",
            "<blockquote", "<pre", "<hr", "<table", "<th", "<td",
        )) {
            assertTrue("HTML missing '$needle'", html.contains(needle))
        }
    }

    // MARK: - Image copy (HTML data: URIs)

    private val imageDoc = RichTextDocument.parse("![cat](https://x.test/cat.png)")

    @Test fun htmlEmbedsImageAsDataURIWhenResolved() {
        val bytes = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A)
        val resolver: RichTextImageResolver = { url ->
            if (url == "https://x.test/cat.png") RichTextInlineImage(bytes, RichTextImageFormat.PNG) else null
        }
        val html = RichTextHTMLSerializer.fragment(imageDoc, resolver)
        assertTrue("expected an embedded PNG data: URI, got $html", html.contains("src=\"data:image/png;base64," + base64(bytes)))
    }

    @Test fun htmlEmbedsJPEGWithJPEGMimeType() {
        val bytes = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE0.toByte())
        val resolver: RichTextImageResolver = { RichTextInlineImage(bytes, RichTextImageFormat.JPEG) }
        val html = RichTextHTMLSerializer.fragment(imageDoc, resolver)
        assertTrue("expected a JPEG data: URI, got $html", html.contains("src=\"data:image/jpeg;base64," + base64(bytes)))
    }

    @Test fun htmlEmbedsGIFWithGIFMimeType() {
        val bytes = byteArrayOf(0x47, 0x49, 0x46, 0x38, 0x39, 0x61)   // GIF89a
        val resolver: RichTextImageResolver = { RichTextInlineImage(bytes, RichTextImageFormat.GIF) }
        val html = RichTextHTMLSerializer.fragment(imageDoc, resolver)
        assertTrue("expected a GIF data: URI, got $html", html.contains("src=\"data:image/gif;base64," + base64(bytes)))
    }

    @Test fun htmlFallsBackToURLWhenImageNotResolved() {
        val html = RichTextHTMLSerializer.fragment(imageDoc)   // default resolver returns null
        assertTrue("expected URL fallback, got $html", html.contains("src=\"https://x.test/cat.png\""))
        assertFalse("should not embed data when unresolved", html.contains("data:image"))
    }

    @Test fun htmlStylesAreInline() {
        val html = RichTextHTMLSerializer.fragment(richDoc)
        for (needle in listOf(
            "border-collapse:collapse", "border:1px solid", "background:#f0f0f0",
            "border-left:3px solid", "border-top:1px solid", "font-size:1.6em",
        )) {
            assertTrue("HTML missing style '$needle'", html.contains(needle))
        }
    }

    // MARK: - URL policy (link scheme gating at the serialize boundary)

    @Test fun htmlJavascriptLinkHasNoHref() {
        val doc = RichTextDocument(listOf(RichTextBlock.Paragraph(listOf(RichTextInline.Link(listOf(RichTextInline.Text("click")), "javascript:alert(1)")))))
        val html = RichTextHTMLSerializer.fragment(doc)
        assertTrue("link text must still render", html.contains("click"))
        assertFalse("javascript: link must not become an <a href>", html.contains("href"))
        assertFalse("javascript: url must not survive into HTML", html.contains("javascript:"))
    }

    @Test fun httpLinkStillEmitsHref() {
        val doc = RichTextDocument(listOf(RichTextBlock.Paragraph(listOf(RichTextInline.Link(listOf(RichTextInline.Text("go")), "https://swift.org")))))
        assertTrue(RichTextHTMLSerializer.fragment(doc).contains("<a href=\"https://swift.org\""))
    }

    // MARK: - Code-fence language sanitization (HTML injection)

    @Test fun htmlCodeBlockLanguageCannotBreakOutOfAttribute() {
        val doc = RichTextDocument(listOf(RichTextBlock.CodeBlock("rust\"><img/src=x/onerror=alert(1)>", "let x = 1")))
        val html = RichTextHTMLSerializer.fragment(doc)
        assertFalse("language must not inject an <img> element", html.contains("<img"))
        assertFalse("language must not inject an event-handler attribute", html.contains("onerror="))
        assertFalse("raw structural characters must not survive into the output", html.contains("/src=x"))
        assertTrue("expected the sanitized class token, got $html", html.contains("class=\"language-rustimgsrcxonerroralert1\""))
        assertTrue("code body should still render", html.contains("let x = 1"))
    }

    @Test fun htmlCodeBlockDropsAttributeWhenLanguageFullyStripped() {
        val doc = RichTextDocument(listOf(RichTextBlock.CodeBlock("\"'><&", "x")))
        val html = RichTextHTMLSerializer.fragment(doc)
        assertFalse("must not inject a <script> element", html.contains("<script"))
        assertFalse("a fully-stripped language must not emit an empty class attribute", html.contains("class="))
        assertTrue("a bare <code> tag should be emitted", html.contains("<code>"))
    }

    // MARK: - Image scheme gating

    @Test fun htmlFileImageFallsBackToAltText() {
        val doc = RichTextDocument(listOf(RichTextBlock.Paragraph(listOf(RichTextInline.Image("secret", "file:///etc/passwd")))))
        val html = RichTextHTMLSerializer.fragment(doc)
        assertFalse("must never emit a file: image src", html.contains("file:"))
        assertFalse("a disallowed image scheme must not become an <img>", html.contains("<img"))
        assertTrue("alt text should remain", html.contains("secret"))
    }

    @Test fun htmlHTTPSImageStillEmittedWhenUnresolved() {
        val doc = RichTextDocument(listOf(RichTextBlock.Paragraph(listOf(RichTextInline.Image("cat", "https://x.test/cat.png")))))
        val html = RichTextHTMLSerializer.fragment(doc)
        assertTrue("allow-listed image URL should survive", html.contains("src=\"https://x.test/cat.png\""))
    }
}
