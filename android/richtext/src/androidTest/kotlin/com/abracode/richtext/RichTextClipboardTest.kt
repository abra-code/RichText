package com.abracode.richtext

import com.abracode.richtext.model.RichTextDocument
import com.abracode.richtext.serialization.RichTextClipboard
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Stage F clipboard: verifies the two-flavor clip (HTML rich + Markdown plain) is built correctly. Asserts the
 * ClipData payload directly (not via the system clipboard, whose reads are focus-gated on API 31+). ClipData is
 * an Android type, so this runs instrumented.
 */
class RichTextClipboardTest {

    @Test fun buildsHtmlAndMarkdownFlavors() {
        val markdown = "# Title\n\nA paragraph with **bold** and a [link](https://swift.org)."
        val clip = RichTextClipboard.clipData(RichTextDocument.parse(markdown), label = "Doc")

        assertEquals("Doc", clip.description.label)
        // An HTML clip declares the text/html MIME type; the plain-text flavor coexists on the item as item.text.
        assertTrue("declares the HTML MIME type", clip.description.hasMimeType("text/html"))

        val item = clip.getItemAt(0)
        val html = item.htmlText.orEmpty()
        assertTrue("HTML renders strong", html.contains("<strong>bold</strong>"))
        assertTrue("HTML renders the allow-listed link", html.contains("href=\"https://swift.org\""))
        assertTrue("HTML is a full document", html.contains("<h1", ignoreCase = true) || html.contains("<body"))

        val plain = item.text?.toString().orEmpty()
        assertTrue("plain flavor is Markdown", plain.contains("**bold**"))
        assertTrue("plain flavor keeps the heading", plain.contains("# Title"))
    }
}
