package com.abracode.richtext

// URL allow-lists applied at the RENDER / SERIALIZE / IMAGE-LOAD boundaries. The document model keeps the RAW
// url strings from (untrusted, streamed) Markdown losslessly; policy is enforced only where a url would
// otherwise become dangerous: a tappable on-screen link, an href in copied HTML, or an actual network fetch.
// The threats are `javascript:` (script execution from a tapped link or pasted HTML) and `file:` (reading a
// local file off disk). Only explicit, absolute, allow-listed schemes pass; scheme-less/relative strings are
// rejected. A 1:1 port of Sources/RichText/RichTextURLPolicy.swift.
//
// Divergence from Swift: the reference parses with `URL(string:)` and reads `.scheme`. There is no identical
// JVM URL parser, so the scheme is extracted directly per RFC 3986. The security property is unchanged (the
// scheme allow-list is enforced case-insensitively); only whole-URL well-formedness checking is not attempted,
// which is not part of the policy the reference enforces.

object RichTextURLPolicy {

    // Hyperlink targets: navigation-only schemes. `javascript:`, `data:`, `file:`, and anything unknown are
    // rejected so they can never be made tappable or written as an href. (tel is included: harmless dialer intent.)
    val allowedLinkSchemes: Set<String> = setOf("http", "https", "mailto", "tel")

    // Image sources: remote schemes plus `data:` (bytes already inline in the Markdown). `file:` is deliberately
    // EXCLUDED - an untrusted file: image must never be read from disk.
    val allowedImageSchemes: Set<String> = setOf("http", "https", "data")

    /**
     * The URL string for a hyperlink target if its scheme is allow-listed, or null otherwise. A relative /
     * scheme-less string is rejected (a link must carry an explicit, absolute, allow-listed scheme). Scheme
     * comparison is case-insensitive (URL schemes are case-insensitive per RFC 3986, and `javaScript:` is a
     * real bypass).
     */
    fun allowedLink(string: String): String? {
        val scheme = schemeOf(string)?.lowercase() ?: return null
        return if (scheme in allowedLinkSchemes) string else null
    }

    /**
     * Whether an image URL may be fetched AND embedded. True only for an allow-listed scheme (http/https/data);
     * false for file:, javascript:, and scheme-less/relative URLs.
     */
    fun allowsImage(url: String): Boolean {
        val scheme = schemeOf(url)?.lowercase() ?: return false
        return scheme in allowedImageSchemes
    }

    // RFC 3986 scheme: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) terminated by ':'. Returns the scheme (without
    // the ':'), or null when the string does not begin with an absolute scheme - the same distinction Swift's
    // URL(string:).scheme draws between an absolute URL and a relative/scheme-less one.
    private fun schemeOf(s: String): String? {
        if (s.isEmpty() || !s[0].isAsciiAlpha()) return null
        var i = 1
        while (i < s.length) {
            val c = s[i]
            if (c == ':') return s.substring(0, i)
            if (!(c.isAsciiAlpha() || c in '0'..'9' || c == '+' || c == '-' || c == '.')) return null
            i++
        }
        return null
    }

    private fun Char.isAsciiAlpha(): Boolean = this in 'a'..'z' || this in 'A'..'Z'
}
