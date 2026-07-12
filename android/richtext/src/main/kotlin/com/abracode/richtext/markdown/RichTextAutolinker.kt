package com.abracode.richtext.markdown

import com.abracode.richtext.model.RichTextInline

// A post-pass over inline nodes that turns bare URLs in plain text into links (GFM-style autolinking), so a URL
// typed without [](...) is still tappable. It runs after inline parsing, walking only `Text` nodes and recursing
// into emphasis / strong / strikethrough - it deliberately does NOT touch `Code` or an existing `Link` (so a URL
// inside inline code, or the visible text of a real link, is left alone).
//
// DIVERGENCE #7 (section 8 of the porting plan): the Swift reference detects URLs with NSDataDetector, an
// Apple-only API with no JVM/Android equivalent. This is a hand-rolled scanner in its place. It matches the
// behaviors the reference's tests pin - `http(s)://` URLs, `www.`-prefixed hosts promoted to `http://`, trailing
// sentence-punctuation excluded, code / existing links left alone - but does NOT attempt NSDataDetector's fuller
// heuristics (bare-email -> mailto:, ftp/other schemes, IDN, exotic TLDs). Cross-platform fixtures (Stage C)
// steer clear of those edge cases.

internal object RichTextAutolinker {

    fun link(nodes: List<RichTextInline>): List<RichTextInline> = apply(nodes)

    private fun apply(nodes: List<RichTextInline>): List<RichTextInline> =
        nodes.flatMap { node ->
            when (node) {
                is RichTextInline.Text -> split(node.value)
                is RichTextInline.Emphasis -> listOf(RichTextInline.Emphasis(apply(node.children)))
                is RichTextInline.Strong -> listOf(RichTextInline.Strong(apply(node.children)))
                is RichTextInline.Strikethrough -> listOf(RichTextInline.Strikethrough(apply(node.children)))
                is RichTextInline.Code,
                is RichTextInline.Link,
                is RichTextInline.Image,
                RichTextInline.LineBreak -> listOf(node)
            }
        }

    // Splits one plain-text run into alternating text / link nodes. Returns a single text node when it holds no
    // detectable URL (matching the reference, which returns the text unchanged).
    private fun split(text: String): List<RichTextInline> {
        if (text.isEmpty()) return listOf(RichTextInline.Text(text))
        val result = mutableListOf<RichTextInline>()
        val plain = StringBuilder()
        var i = 0
        while (i < text.length) {
            val match = matchUrlAt(text, i)
            if (match != null) {
                if (plain.isNotEmpty()) {
                    result.add(RichTextInline.Text(plain.toString()))
                    plain.setLength(0)
                }
                result.add(RichTextInline.Link(listOf(RichTextInline.Text(match.display)), match.href))
                i += match.display.length
            } else {
                plain.append(text[i])
                i++
            }
        }
        if (plain.isNotEmpty()) result.add(RichTextInline.Text(plain.toString()))
        return if (result.isEmpty()) listOf(RichTextInline.Text(text)) else result
    }

    private class Match(val display: String, val href: String)

    private val schemePrefixes = listOf("https://", "http://")

    // Attempts to match a URL that STARTS at index i. A URL may only begin at a boundary (start of the run, or
    // after a non-alphanumeric character) so "xhttps://..." or "awww.x" inside a word are not mis-detected.
    private fun matchUrlAt(text: String, i: Int): Match? {
        if (i != 0 && text[i - 1].isLetterOrDigit()) return null

        for (scheme in schemePrefixes) {
            if (text.regionMatches(i, scheme, 0, scheme.length, ignoreCase = true)) {
                val display = trimTrailingPunctuation(consumeUrl(text, i))
                // Require something after "scheme://": a bare "https://" is not a link.
                if (display.length <= scheme.length) return null
                return Match(display, display)
            }
        }

        if (text.regionMatches(i, WWW_PREFIX, 0, WWW_PREFIX.length, ignoreCase = true)) {
            val display = trimTrailingPunctuation(consumeUrl(text, i))
            // Require at least one more character after "www.".
            if (display.length <= WWW_PREFIX.length) return null
            return Match(display, "http://$display")
        }

        return null
    }

    // Consumes the URL body: everything from `start` up to the first whitespace or angle bracket. Trailing
    // punctuation is trimmed separately so a URL at the end of a sentence keeps its host but drops the period.
    private fun consumeUrl(text: String, start: Int): String {
        var j = start
        while (j < text.length) {
            val c = text[j]
            if (c.isWhitespace() || c == '<' || c == '>') break
            j++
        }
        return text.substring(start, j)
    }

    // Drops trailing sentence punctuation the way NSDataDetector does. Closing brackets are only dropped when
    // unbalanced, so a URL like https://en.wikipedia.org/wiki/Foo_(bar) keeps its closing paren.
    //
    // Linear in the URL length: the bracket balances over the full string are computed once, then maintained as
    // trailing brackets are dropped. (A naive re-scan per trailing bracket is O(n^2), which a long run of
    // trailing ')' / ']' / '}' - reachable from untrusted, re-parsed-per-token input - would turn into a DoS.)
    private fun trimTrailingPunctuation(url: String): String {
        var openParen = 0; var closeParen = 0
        var openSquare = 0; var closeSquare = 0
        var openBrace = 0; var closeBrace = 0
        for (c in url) {
            when (c) {
                '(' -> openParen++
                ')' -> closeParen++
                '[' -> openSquare++
                ']' -> closeSquare++
                '{' -> openBrace++
                '}' -> closeBrace++
            }
        }
        var end = url.length
        while (end > 0) {
            val c = url[end - 1]
            // Counts currently reflect the prefix [0, end), which includes `c`; the bracket test matches the
            // reference's "more closers than openers so far" rule.
            val trim = when {
                c in ALWAYS_TRIM -> true
                c == ')' -> closeParen > openParen
                c == ']' -> closeSquare > openSquare
                c == '}' -> closeBrace > openBrace
                else -> false
            }
            if (!trim) break
            when (c) {   // drop `c` from the running counts as it leaves the prefix
                '(' -> openParen--
                ')' -> closeParen--
                '[' -> openSquare--
                ']' -> closeSquare--
                '{' -> openBrace--
                '}' -> closeBrace--
            }
            end--
        }
        return url.substring(0, end)
    }

    private const val WWW_PREFIX = "www."
    private const val ALWAYS_TRIM = ".,;:!?\"'"
}
