package com.abracode.richtext.serialization

import com.abracode.richtext.RichTextURLPolicy
import com.abracode.richtext.model.RichTextBlock
import com.abracode.richtext.model.RichTextColumnAlignment
import com.abracode.richtext.model.RichTextDocument
import com.abracode.richtext.model.RichTextInline
import java.util.Base64

// Model -> HTML. A real <table> (and the other blocks), for web / rich paste targets. Blocks carry INLINE
// styles (style="...", not a <style> block or CSS classes) so the look survives paste into targets that strip
// stylesheets and classes (Notes, Word, Pages): table borders + header shade, the code-block / inline-code
// background, the block-quote bar, heading sizes, and the rule. Colors are fixed light-mode hexes - a pasted
// document is static, so it cannot track the system appearance. A 1:1 port of
// Sources/RichText/Serialization/RichTextHTMLSerializer.swift; the output must match byte-for-byte.

object RichTextHTMLSerializer {

    private val noImages: RichTextImageResolver = { null }

    /**
     * An HTML fragment (no <html>/<body> wrapper). `images` resolves an image URL to its loaded bytes so they
     * can be embedded as a data: URI (unresolved images keep the URL).
     */
    fun fragment(document: RichTextDocument, images: RichTextImageResolver = noImages): String =
        document.blocks.joinToString("\n") { block(it, images) }

    /** A full HTML document. */
    fun document(document: RichTextDocument, images: RichTextImageResolver = noImages): String =
        "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"></head><body>\n" +
            fragment(document, images) + "\n</body></html>"

    // MARK: - Style palette (fixed light-mode values; inline so they survive paste)

    private object Css {
        const val BORDER = "#c8c8c8"
        const val FILL = "#f0f0f0"
        const val SECONDARY = "#6b6b6b"
        const val LINK = "#0066cc"
        const val MONO = "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"

        const val TABLE = "border-collapse:collapse;margin:0.5em 0"
        const val CELL = "border:1px solid $BORDER;padding:5px 7px"
        const val HEADER_CELL = "$CELL;background:$FILL"
        const val CODE_BLOCK = "background:$FILL;border-radius:6px;padding:8px 10px;overflow:auto;" +
            "font-family:$MONO;font-size:0.94em;white-space:pre"
        const val INLINE_CODE = "background:$FILL;border-radius:4px;padding:0.1em 0.3em;" +
            "font-family:$MONO;font-size:0.94em"
        const val QUOTE = "border-left:3px solid $BORDER;margin:0.5em 0;padding:0 0 0 10px;color:$SECONDARY"
        const val RULE = "border:none;border-top:1px solid $BORDER;margin:0.6em 0"
        const val ANCHOR = "color:$LINK"

        fun heading(level: Int): String {
            val size = when (level) {
                1 -> "1.6em"
                2 -> "1.4em"
                3 -> "1.2em"
                4 -> "1.05em"
                else -> "1em"
            }
            return "font-weight:600;margin:0.5em 0 0.2em;font-size:$size"
        }
    }

    // MARK: - Blocks

    private fun block(block: RichTextBlock, images: RichTextImageResolver): String = when (block) {
        is RichTextBlock.Heading ->
            "<h${block.level} style=\"${Css.heading(block.level)}\">" + inline(block.inlines, images) + "</h${block.level}>"
        is RichTextBlock.Paragraph ->
            "<p>" + inline(block.inlines, images) + "</p>"
        is RichTextBlock.CodeBlock -> {
            // The language comes from an untrusted fenced-code info string; restrict it to a safe class token so
            // it cannot break out of the attribute / <code> tag (an HTML-injection vector into pasteboard HTML).
            val cls = block.language?.let { sanitizeLanguage(it) }
                ?.let { if (it.isEmpty()) null else " class=\"language-$it\"" } ?: ""
            "<pre style=\"${Css.CODE_BLOCK}\"><code$cls>" + escape(block.code) + "</code></pre>"
        }
        is RichTextBlock.BlockQuote ->
            "<blockquote style=\"${Css.QUOTE}\">\n" + block.blocks.joinToString("\n") { block(it, images) } + "\n</blockquote>"
        is RichTextBlock.ListBlock -> {
            val tag = if (block.ordered) "ol" else "ul"
            val startAttr = if (block.ordered && block.start != 1) " start=\"${block.start}\"" else ""
            val body = block.items.joinToString("\n") { item ->
                "<li>" + item.joinToString("\n") { block(it, images) } + "</li>"
            }
            "<$tag$startAttr>\n" + body + "\n</$tag>"
        }
        RichTextBlock.ThematicBreak ->
            "<hr style=\"${Css.RULE}\">"
        is RichTextBlock.Table ->
            table(block.headers, block.alignments, block.rows, images)
    }

    private fun table(
        headers: List<List<RichTextInline>>,
        alignments: List<RichTextColumnAlignment>,
        rows: List<List<List<RichTextInline>>>,
        images: RichTextImageResolver,
    ): String {
        fun alignmentCss(c: Int): String {
            val a = if (c < alignments.size) alignments[c] else RichTextColumnAlignment.NONE
            return when (a) {
                RichTextColumnAlignment.LEFT -> ";text-align:left"
                RichTextColumnAlignment.CENTER -> ";text-align:center"
                RichTextColumnAlignment.RIGHT -> ";text-align:right"
                RichTextColumnAlignment.NONE -> ""
            }
        }
        val out = StringBuilder("<table style=\"${Css.TABLE}\">\n<thead>\n<tr>")
        for ((c, cell) in headers.withIndex()) {
            out.append("<th style=\"${Css.HEADER_CELL}${alignmentCss(c)}\">").append(inline(cell, images)).append("</th>")
        }
        out.append("</tr>\n</thead>\n<tbody>\n")
        for (row in rows) {
            out.append("<tr>")
            for ((c, cell) in row.withIndex()) {
                out.append("<td style=\"${Css.CELL}${alignmentCss(c)}\">").append(inline(cell, images)).append("</td>")
            }
            out.append("</tr>\n")
        }
        out.append("</tbody>\n</table>")
        return out.toString()
    }

    // MARK: - Inline

    private fun inline(nodes: List<RichTextInline>, images: RichTextImageResolver): String {
        val out = StringBuilder()
        for (node in nodes) {
            when (node) {
                is RichTextInline.Text -> out.append(escape(node.value))
                is RichTextInline.Emphasis -> out.append("<em>").append(inline(node.children, images)).append("</em>")
                is RichTextInline.Strong -> out.append("<strong>").append(inline(node.children, images)).append("</strong>")
                is RichTextInline.Strikethrough -> out.append("<del>").append(inline(node.children, images)).append("</del>")
                is RichTextInline.Code -> out.append("<code style=\"${Css.INLINE_CODE}\">").append(escape(node.value)).append("</code>")
                is RichTextInline.Link -> {
                    // Only wrap in <a href> for an allow-listed scheme, else emit just the child inlines so a
                    // javascript: target cannot survive into pasteboard HTML.
                    if (RichTextURLPolicy.allowedLink(node.url) != null) {
                        out.append("<a href=\"").append(escapeAttribute(node.url)).append("\" style=\"${Css.ANCHOR}\">")
                            .append(inline(node.text, images)).append("</a>")
                    } else {
                        out.append(inline(node.text, images))
                    }
                }
                is RichTextInline.Image -> {
                    val loaded = images(node.url)
                    if (loaded != null) {
                        // Resolved: embed the bytes as a data: URI (survives paste). Only images that passed the
                        // load-time scheme gate are ever resolved, so an embedded data: URI here is safe.
                        val src = "data:" + loaded.format.mimeType + ";base64," + Base64.getEncoder().encodeToString(loaded.data)
                        out.append("<img src=\"").append(src).append("\" alt=\"").append(escapeAttribute(node.alt)).append("\" style=\"max-width:100%\">")
                    } else if (RichTextURLPolicy.allowsImage(node.url)) {
                        // Unresolved but an allow-listed scheme (http/https/data): keep the URL as the src.
                        out.append("<img src=\"").append(escapeAttribute(node.url)).append("\" alt=\"").append(escapeAttribute(node.alt)).append("\" style=\"max-width:100%\">")
                    } else {
                        // Disallowed scheme (e.g. file:) and not embedded: fall back to the alt text - never emit
                        // <img src="file:..."> (a local-file read / exfiltration vector).
                        out.append(escape(node.alt))
                    }
                }
                RichTextInline.LineBreak -> out.append("<br>")
            }
        }
        return out.toString()
    }

    private fun escape(s: String): String =
        s.replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")

    private fun escapeAttribute(s: String): String = escape(s).replace("\"", "&quot;")

    // A code-fence language is emitted into a `language-...` CSS class. Keep only characters valid in a
    // restricted identifier so a crafted info string cannot close the attribute or the <code> tag.
    private fun sanitizeLanguage(s: String): String {
        val allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._+-"
        return s.filter { it in allowed }
    }
}
