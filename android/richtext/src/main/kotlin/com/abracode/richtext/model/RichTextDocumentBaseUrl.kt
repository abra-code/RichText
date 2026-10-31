package com.abracode.richtext.model

import com.abracode.richtext.RichTextURLPolicy
import java.net.URI

// Relative image paths resolved against the document's own location: `![](img/a.png)` in a Markdown file on
// disk names a picture beside that file. A string of Markdown has no location, so the caller supplies it.
// A port of Sources/RichText/Model/RichTextDocument+BaseURL.swift.
//
// Where java.net.URI differs from Swift's URL, the code below gives Swift's strings: the relative path is
// percent-encoded first as URL(string:) encodes it, ".." stops at the root, and a resolved file: URL gets its
// empty authority back (java.net.URI writes `file:///x` as `file:/x`).

/**
 * A copy whose relative image URLs (those without a scheme, such as `img/a.png`, `../b.jpg` or `/c.png`) are
 * resolved against [base], the document's own URL: a file's URL (`file:///docs/read.md`), a folder's URL ending
 * in "/", or a web page's URL. [base] must be a valid URL string, as `Uri.fromFile(file).toString()` gives (a
 * raw space does not parse, and then nothing is resolved). Absolute URLs, links and everything else are left as
 * they are, and a path that cannot be resolved stays relative (its image is unavailable).
 */
fun RichTextDocument.resolvingImageUrls(base: String): RichTextDocument {
    val baseUri = try {
        URI(base)
    } catch (e: Exception) {
        return this
    }
    return RichTextDocument(blocks.map { it.resolvingImageUrls(baseUri) })
}

private fun RichTextBlock.resolvingImageUrls(base: URI): RichTextBlock = when (this) {
    is RichTextBlock.Heading -> copy(inlines = inlines.resolvingImageUrls(base))
    is RichTextBlock.Paragraph -> copy(inlines = inlines.resolvingImageUrls(base))
    is RichTextBlock.BlockQuote -> copy(blocks = blocks.map { it.resolvingImageUrls(base) })
    is RichTextBlock.ListBlock -> copy(items = items.map { item -> item.map { it.resolvingImageUrls(base) } })
    is RichTextBlock.Table -> copy(
        headers = headers.map { it.resolvingImageUrls(base) },
        rows = rows.map { row -> row.map { it.resolvingImageUrls(base) } },
    )
    is RichTextBlock.CodeBlock, RichTextBlock.ThematicBreak -> this
}

private fun List<RichTextInline>.resolvingImageUrls(base: URI): List<RichTextInline> =
    map { it.resolvingImageUrls(base) }

private fun RichTextInline.resolvingImageUrls(base: URI): RichTextInline = when (this) {
    is RichTextInline.Image -> copy(url = resolvedImageUrl(url, base))
    is RichTextInline.Emphasis -> copy(children = children.resolvingImageUrls(base))
    is RichTextInline.Strong -> copy(children = children.resolvingImageUrls(base))
    is RichTextInline.Strikethrough -> copy(children = children.resolvingImageUrls(base))
    is RichTextInline.Link -> copy(text = text.resolvingImageUrls(base))
    is RichTextInline.Text, is RichTextInline.Code, RichTextInline.LineBreak -> this
}

// `url` resolved against `base` when it has no scheme; otherwise, or when it does not parse, unchanged.
private fun resolvedImageUrl(url: String, base: URI): String {
    if (url.isEmpty() || RichTextURLPolicy.schemeOf(url) != null) return url
    val uri = try {
        base.resolve(URI(encodedReference(url)))
    } catch (e: Exception) {
        return url
    }
    var resolved = uri.toString()
    // java.net.URI keeps ".." segments that climb above the root ("/../a.png"); Swift's URL drops them (RFC 3986).
    val path = uri.rawPath
    if (uri.scheme != null && path != null && (path == "/.." || path.startsWith("/../"))) {
        val prefix = uri.scheme + ":" + (uri.rawAuthority?.let { "//$it" } ?: "")
        if (resolved.startsWith(prefix + path)) {
            var trimmed = path
            while (trimmed.startsWith("/../")) trimmed = trimmed.substring(3)
            if (trimmed == "/..") trimmed = "/"
            resolved = prefix + trimmed + resolved.substring(prefix.length + path.length)
        }
    }
    return if (resolved.startsWith("file:/") && !resolved.startsWith("file://")) {
        "file://" + resolved.removePrefix("file:")
    } else {
        resolved
    }
}

// `reference` with what a URI may not hold percent-encoded as UTF-8 (a space, a letter outside ASCII, "[", "|", a
// "%" that starts no escape, a second "#"), as Swift's URL(string:) encodes it; "?" and the first "#" keep their
// meaning.
private fun encodedReference(reference: String): String {
    val bytes = reference.toByteArray(Charsets.UTF_8)
    val out = StringBuilder()
    var seenHash = false
    for ((i, byte) in bytes.withIndex()) {
        val b = byte.toInt() and 0xFF
        val c = b.toChar()
        val keep = when {
            b >= 0x80 -> false
            c in 'a'..'z' || c in 'A'..'Z' || c in '0'..'9' || c in "-._~!$&'()*+,;=:@/?" -> true
            c == '%' -> i + 2 < bytes.size && isHexDigit(bytes[i + 1]) && isHexDigit(bytes[i + 2])
            c == '#' -> !seenHash
            else -> false
        }
        if (c == '#') seenHash = true
        if (keep) {
            out.append(c)
        } else {
            out.append('%').append(HEX_DIGITS[b shr 4]).append(HEX_DIGITS[b and 0xF])
        }
    }
    return out.toString()
}

private const val HEX_DIGITS = "0123456789ABCDEF"

private fun isHexDigit(byte: Byte): Boolean = byte.toInt().toChar().let { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }
