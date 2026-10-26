package com.abracode.richtext.markdown

import com.abracode.richtext.model.RichTextInline

// A post-pass over inline nodes that turns bare URLs and email addresses in plain text into links (GFM's
// autolink extension), so a URL typed without [](...) is still tappable. It runs after inline parsing, walking
// only `Text` nodes and recursing into emphasis / strong / strikethrough - it deliberately does NOT touch `Code`
// or an existing `Link` (so a URL inside inline code, or the visible text of a real link, is left alone).
//
// A 1:1 port of the Swift RichTextAutolinker: the rules are those of cmark-gfm's autolink extension, the parser
// behind Apple's AttributedString(markdown:), so a bare URL links where it does in SwiftUI's Text:
// - http://, https:// and ftp:// URLs, and www. hosts (lower case, after a space, a line start or one of
//   * _ ~ ( ), which get http://; a bare domain such as example.com stays text.
// - email addresses, which get mailto:, and mailto: and xmpp: addresses as written.
// - the URL runs to a space or a '<', then trailing ? ! . , : * _ ~ ' " are dropped, an unbalanced ')', and a
//   trailing entity-like "&name;".
// - a host with an underscore in one of its last two labels is not linked, unless it has more than 10 labels.
// It works on code points, as the Swift version works on Unicode scalars.

internal object RichTextAutolinker {

    fun link(nodes: List<RichTextInline>): List<RichTextInline> {
        val result = mutableListOf<RichTextInline>()
        var index = 0
        while (index < nodes.size) {
            when (val node = nodes[index]) {
                is RichTextInline.Text -> {
                    // Adjacent text nodes are scanned as one text, as a URL may span them.
                    var end = index
                    val text = StringBuilder()
                    while (end < nodes.size) {
                        val piece = nodes[end] as? RichTextInline.Text ?: break
                        text.append(piece.value)
                        end++
                    }
                    val linked = split(text.toString(), wwwMayFollow(if (index == 0) null else nodes[index - 1]))
                    if (linked.size == 1 && linked[0] is RichTextInline.Text) {
                        result.addAll(nodes.subList(index, end))
                    } else {
                        result.addAll(linked)
                    }
                    index = end
                }
                is RichTextInline.Emphasis -> {
                    result.add(RichTextInline.Emphasis(link(node.children)))
                    index++
                }
                is RichTextInline.Strong -> {
                    result.add(RichTextInline.Strong(link(node.children)))
                    index++
                }
                is RichTextInline.Strikethrough -> {
                    result.add(RichTextInline.Strikethrough(link(node.children)))
                    index++
                }
                is RichTextInline.Code,
                is RichTextInline.Link,
                is RichTextInline.Image,
                RichTextInline.LineBreak -> {
                    result.add(node)
                    index++
                }
            }
        }
        return result
    }

    // Whether a www. host at the start of a text may link after `previous`: cmark-gfm allows one after a line
    // start, a space, or * _ ~ (, which is what precedes text that begins a paragraph or an emphasis span or
    // follows one; not after the backtick of a code span or the ')' of a link or image.
    private fun wwwMayFollow(previous: RichTextInline?): Boolean = when (previous) {
        null,
        is RichTextInline.Emphasis,
        is RichTextInline.Strong,
        is RichTextInline.Strikethrough,
        RichTextInline.LineBreak -> true
        is RichTextInline.Text,
        is RichTextInline.Code,
        is RichTextInline.Link,
        is RichTextInline.Image -> false
    }

    // MARK: Splitting a text

    private class Found(val start: Int, val end: Int, val url: String)

    private fun split(text: String, wwwAllowedAtStart: Boolean): List<RichTextInline> {
        val s = text.codePoints().toArray()
        val found = mutableListOf<Found>()
        // URLs and www. hosts, left to right, as cmark-gfm finds them while it parses the line.
        var position = 0
        var segmentStart = 0
        while (position < s.size) {
            val c = s[position]
            val match = when (c) {
                ':'.code -> urlMatch(s, position, segmentStart)
                'w'.code -> {
                    val allowed = if (position == 0) wwwAllowedAtStart else wwwMayFollow(s[position - 1])
                    if (allowed) wwwMatch(s, position) else null
                }
                else -> null
            }
            if (match != null) {
                found.add(match)
                position = match.end
                segmentStart = match.end
            } else {
                position++
            }
        }
        // Then email addresses, in the text left between them (cmark-gfm's pass after parsing).
        val all = mutableListOf<Found>()
        var cursor = 0
        for (link in found + Found(s.size, s.size, "")) {
            all.addAll(emailMatches(s, cursor, link.start))
            if (link.start < link.end) all.add(link)
            cursor = link.end
        }
        if (all.isEmpty()) return listOf(RichTextInline.Text(text))
        val result = mutableListOf<RichTextInline>()
        cursor = 0
        for (link in all) {
            if (link.start > cursor) result.add(RichTextInline.Text(string(s, cursor, link.start)))
            result.add(RichTextInline.Link(listOf(RichTextInline.Text(string(s, link.start, link.end))), link.url))
            cursor = link.end
        }
        if (cursor < s.size) result.add(RichTextInline.Text(string(s, cursor, s.size)))
        return result
    }

    private fun wwwMayFollow(c: Int): Boolean =
        c == '*'.code || c == '_'.code || c == '~'.code || c == '('.code || isSpace(c)

    // MARK: Matchers (cmark-gfm's extensions/autolink.c)

    // A URL whose "://" starts at `colon`: the scheme is the letters before it (not before `from`, the end of the
    // previous link), and must be http, https or ftp.
    private fun urlMatch(s: IntArray, colon: Int, from: Int): Found? {
        if (colon + 3 >= s.size || s[colon + 1] != '/'.code || s[colon + 2] != '/'.code) return null
        var start = colon
        while (start > from && isAlpha(s[start - 1])) start--
        val scheme = string(s, start, colon).lowercase()
        if ((scheme != "http" && scheme != "https" && scheme != "ftp") || !isHostChar(s[colon + 3])) return null
        val domain = domainLength(s, colon + 3, allowShort = true) ?: return null
        var end = colon + 3 + domain
        while (end < s.size && !isSpace(s[end]) && s[end] != '<'.code) end++
        end = trimmedEnd(s, start, end)
        return Found(start, end, string(s, start, end))
    }

    private fun wwwMatch(s: IntArray, start: Int): Found? {
        if (start + 4 > s.size || s[start] != 'w'.code || s[start + 1] != 'w'.code || s[start + 2] != 'w'.code ||
            s[start + 3] != '.'.code
        ) return null
        val domain = domainLength(s, start, allowShort = false) ?: return null
        var end = start + domain
        while (end < s.size && !isSpace(s[end]) && s[end] != '<'.code) end++
        end = trimmedEnd(s, start, end)
        if (end <= start) return null
        return Found(start, end, "http://" + string(s, start, end))
    }

    // The length of the host at `from` (its first character is taken as valid), or null when an underscore is in
    // one of its last two labels, or when `allowShort` is false and it has no dot. Like cmark-gfm's check_domain,
    // it never looks at the text's last character.
    private fun domainLength(s: IntArray, from: Int, allowShort: Boolean): Int? {
        val size = s.size - from
        var i = 1
        var dots = 0
        var underscoresBefore = 0
        var underscores = 0
        while (i < size - 1) {
            if (s[from + i] == '\\'.code && i < size - 2) i++
            val c = s[from + i]
            if (c == '_'.code) {
                underscores++
            } else if (c == '.'.code) {
                underscoresBefore = underscores
                underscores = 0
                dots++
            } else if (!isHostChar(c) && c != '-'.code) {
                break
            }
            i++
        }
        // A host of more than 10 labels is taken despite the underscores, as cmark-gfm does: without this a run of
        // "_www." hosts makes the scan quadratic.
        if ((underscoresBefore > 0 || underscores > 0) && dots <= 10) return null
        if (!allowShort && dots == 0) return null
        return maxOf(i, 1)
    }

    // Where a link from `start` to `end` really ends: before any '<', without trailing punctuation, an unbalanced
    // ')' or a trailing "&name;" (cmark-gfm's autolink_delim).
    private fun trimmedEnd(s: IntArray, start: Int, end: Int): Int {
        var end = end
        for (k in start until end) {
            if (s[k] == '<'.code) {
                end = k
                break
            }
        }
        var opening = 0
        var closing = 0
        for (k in start until end) {
            if (s[k] == '('.code) opening++ else if (s[k] == ')'.code) closing++
        }
        while (end > start) {
            val last = s[end - 1]
            if (last < 128 && TRAILING.indexOf(last.toChar()) >= 0) {
                end--
            } else if (last == ';'.code) {
                var entityStart = end - 2
                while (entityStart > start && isAlpha(s[entityStart])) entityStart--
                if (entityStart < end - 2 && s[entityStart] == '&'.code) end = entityStart else end--
            } else if (last == ')'.code && closing > opening) {
                // Only a ')' changes the counts: the other dropped characters are not brackets.
                closing--
                end--
            } else {
                break
            }
        }
        return end
    }

    // Email addresses in s[from until to] (cmark-gfm's postprocess_text): local part letters, digits and
    // . + - _, a domain of letters, digits, - and _ with a dot followed by a letter or digit, ending in a letter
    // or a dot (dropped). "mailto:" or "xmpp:" right before the local part is kept in the link.
    private fun emailMatches(s: IntArray, from: Int, to: Int): List<Found> {
        val result = mutableListOf<Found>()
        var offset = from
        while (offset < to) {
            var at = -1
            for (k in offset until to) {
                if (s[k] == '@'.code) {
                    at = k
                    break
                }
            }
            if (at < 0) break
            var rewind = 0
            var autoMailto = true
            var isXMPP = false
            while (at - rewind > offset) {
                val c = s[at - rewind - 1]
                if (isAlnum(c) || (c < 128 && ".+-_".indexOf(c.toChar()) >= 0)) {
                    rewind++
                    continue
                }
                if (c == ':'.code) {
                    if (hasProtocol("mailto:", s, at - rewind, offset)) {
                        autoMailto = false
                        rewind++
                        continue
                    }
                    if (hasProtocol("xmpp:", s, at - rewind, offset)) {
                        autoMailto = false
                        isXMPP = true
                        rewind++
                        continue
                    }
                }
                break
            }
            if (rewind == 0) {
                offset = at + 1
                continue
            }
            var end = at
            var ats = 0
            var dots = 0
            while (end < to) {
                val c = s[end]
                if (isAlnum(c)) {
                    end++
                    continue
                }
                if (c == '@'.code) {
                    ats++
                    // No address now: stopping here keeps a long run of @s linear.
                    if (ats > 1) break
                } else if (c == '.'.code && end < to - 1 && isAlnum(s[end + 1])) {
                    dots++
                } else if (c == '/'.code && isXMPP) {
                    end++
                    continue
                } else if (c != '-'.code && c != '_'.code) {
                    break
                }
                end++
            }
            val length = end - at
            if (length < 2 || ats != 1 || dots == 0 || (!isAlpha(s[end - 1]) && s[end - 1] != '.'.code)) {
                offset = at + 1
                continue
            }
            end = trimmedEnd(s, at, end)
            if (end == at) {
                offset = at + 1
                continue
            }
            val start = at - rewind
            val address = string(s, start, end)
            result.add(Found(start, end, if (autoMailto) "mailto:$address" else address))
            offset = end
        }
        return result
    }

    // Whether `name` ("mailto:") ends right before `before`, at `from` or after a character that is not a letter or
    // digit.
    private fun hasProtocol(name: String, s: IntArray, before: Int, from: Int): Boolean {
        val start = before - name.length
        if (start < from || string(s, start, before) != name) return false
        return start == from || !isAlnum(s[start - 1])
    }

    // MARK: Character classes (cmark's, which are ASCII but for the host characters)

    private fun isAlpha(c: Int): Boolean = (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code)

    private fun isAlnum(c: Int): Boolean = isAlpha(c) || (c >= '0'.code && c <= '9'.code)

    private fun isSpace(c: Int): Boolean = c == ' '.code || (c in 9..13)

    // A host character: not white space and not punctuation, in Unicode's sense.
    private fun isHostChar(c: Int): Boolean {
        if (c < 128) return !isSpace(c) && ASCII_PUNCTUATION.indexOf(c.toChar()) < 0
        return when (Character.getType(c).toByte()) {
            Character.SPACE_SEPARATOR,
            Character.CONNECTOR_PUNCTUATION,
            Character.DASH_PUNCTUATION,
            Character.START_PUNCTUATION,
            Character.END_PUNCTUATION,
            Character.INITIAL_QUOTE_PUNCTUATION,
            Character.FINAL_QUOTE_PUNCTUATION,
            Character.OTHER_PUNCTUATION -> false
            else -> true
        }
    }

    private fun string(s: IntArray, start: Int, end: Int): String = String(s, start, end - start)

    private const val TRAILING = "?!.,:*_~'\""
    private const val ASCII_PUNCTUATION = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
}
