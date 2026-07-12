package com.abracode.richtext.serialization

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import com.abracode.richtext.model.RichTextDocument

/**
 * Writes a document to the system clipboard in two representations so each paste target picks the richest it
 * supports: HTML (the rich flavor) plus Markdown as the plain-text flavor. The Android analog of Swift's
 * `RichTextPasteboard` - `ClipData.newHtmlText` carries exactly these two flavors. RTF is not available on
 * Android (section-8 divergence #2); the HTML flavor is the rich representation.
 *
 * Images render as their URLs in the HTML (a paste target fetches them); unlike Swift, already-cached image
 * bytes are not embedded as data: URIs - a minor reduction inside the no-RTF clipboard divergence.
 */
object RichTextClipboard {

    /** Replaces the primary clip with [document] as HTML (rich) + Markdown (plain). */
    fun write(document: RichTextDocument, context: Context, label: CharSequence = "RichText") {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(clipData(document, label))
    }

    /** Convenience: parse [markdown] and write it. */
    fun write(markdown: String, context: Context, label: CharSequence = "RichText") {
        write(RichTextDocument.parse(markdown), context, label)
    }

    /**
     * Builds the two-flavor [ClipData] (HTML rich + Markdown plain) without touching the system clipboard.
     * Exposed so the payload can be asserted without needing window focus (clipboard reads are focus-gated).
     */
    fun clipData(document: RichTextDocument, label: CharSequence = "RichText"): ClipData {
        val plain = RichTextMarkdownSerializer.string(document)
        val html = RichTextHTMLSerializer.document(document)
        return ClipData.newHtmlText(label, plain, html)
    }
}
