package com.abracode.richtext.search

import com.abracode.richtext.model.RichTextBlock
import com.abracode.richtext.model.RichTextDocument
import com.abracode.richtext.model.RichTextInline
import com.abracode.richtext.model.plainText
import com.abracode.richtext.rendering.RichTextRenderedText
import java.text.Normalizer

// Port of Sources/RichText/Search/RichTextSearch.swift - the find ENGINE: pure functions from text + query to
// match ranges, with no composable, no state and nothing platform-specific. It is the bottom of a three-layer
// stack: (1) this engine, usable headless by an indexer or a host searching documents it never renders; (2)
// RichTextHighlights, a value the RichText composable paints; (3) RichTextFindController / RichTextFindBar, the
// standalone find UI over one document. Each layer is usable without the one above it.
//
// Matches are UTF-16 offsets into the RENDERED text - RichTextRenderedText.layout(document).text, the block
// texts the composables draw joined by newlines (plan divergence #8: Apple has one text view and one string;
// here the string is assembled from the per-block texts in draw order, so a range still names exactly what is on
// screen and maps back to its block). Kotlin String indices are UTF-16 code units like NSString's, so the Swift
// tests port unchanged.

/** How a query is matched. All default to the forgiving setting a find bar wants; an indexer can tighten them. */
data class RichTextSearchOptions(
    val caseSensitive: Boolean = false,
    val diacriticSensitive: Boolean = false,
    /** Match only where the query is bounded by non-word characters (letters, digits, underscore) or the text's ends. */
    val wholeWord: Boolean = false,
    /** Stop after this many matches (null: unbounded). A one-letter query over a long document yields thousands. */
    val limit: Int? = null,
    /** How many characters of context [RichTextMatch.snippet] keeps on either side of the match. */
    val snippetContext: Int = 40,
) {
    companion object {
        val Default = RichTextSearchOptions()
    }
}

/** A UTF-16 range in the rendered text, end-exclusive (the Kotlin twin of an NSRange). */
data class RichTextRange(val start: Int, val end: Int) {
    val length: Int get() = end - start
    val isEmpty: Boolean get() = end <= start

    /** The overlap with [other], or null when they do not overlap. */
    fun intersect(other: RichTextRange): RichTextRange? {
        val s = maxOf(start, other.start)
        val e = minOf(end, other.end)
        return if (e > s) RichTextRange(s, e) else null
    }

    fun shifted(by: Int): RichTextRange = RichTextRange(start + by, end + by)
}

/** One hit: where it is in the rendered text, and a little context to show in a result list. */
data class RichTextMatch(
    val range: RichTextRange,
    /**
     * The line the match is on, trimmed to `snippetContext` characters on each side of the hit with an ellipsis
     * where it was cut, whitespace collapsed and attachment placeholders dropped. The match itself is always kept
     * whole.
     */
    val snippet: String,
    /** Where the match sits inside [snippet] (UTF-16), so a result list can emphasize it. */
    val rangeInSnippet: RichTextRange,
)

object RichTextSearch {

    /**
     * Every non-overlapping match of [query] in [text], in document order, ranges only - the cheap form for a
     * find bar that shows a count and paints and never displays a snippet. An empty (or all-whitespace) query
     * matches nothing: a find bar being cleared must not light up the document.
     */
    fun ranges(text: String, query: String, options: RichTextSearchOptions = RichTextSearchOptions.Default): List<RichTextRange> {
        if (query.isBlank()) return emptyList()
        val haystack = Folded.of(text, options)
        val needle = Folded.of(query, options).text
        if (needle.isEmpty()) return emptyList()
        val result = mutableListOf<RichTextRange>()
        var cursor = 0
        while (cursor < haystack.text.length) {
            val limit = options.limit
            if (limit != null && result.size >= limit) break
            val at = haystack.text.indexOf(needle, cursor)
            if (at < 0) break
            val found = RichTextRange(haystack.origin[at], haystack.originEnd(at + needle.length))
            if (found.isEmpty) {
                cursor = at + 1
                continue
            }
            if (!options.wholeWord || isWholeWord(found, text)) {
                result.add(found)
                cursor = at + needle.length
            } else {
                // A rejected candidate may still contain the start of an accepted one ("kno no no" for
                // "no no"): move one character on, not past the whole candidate.
                cursor = at + 1
            }
        }
        return result
    }

    /** [ranges] plus a snippet per match, for a result list. */
    fun matches(text: String, query: String, options: RichTextSearchOptions = RichTextSearchOptions.Default): List<RichTextMatch> =
        ranges(text, query, options).map { range ->
            val (snippet, inner) = snippet(range, text, options.snippetContext)
            RichTextMatch(range, snippet, inner)
        }

    /**
     * Headless search over a document: the ranges are the ones `RichText(highlights = ...)` paints for the same
     * document, because both address [RichTextRenderedText.layout]'s text.
     */
    fun matches(document: RichTextDocument, query: String, options: RichTextSearchOptions = RichTextSearchOptions.Default): List<RichTextMatch> =
        matches(RichTextRenderedText.layout(document).text, query, options)

    // --- Folding: a case- / diacritic-folded copy of the text with a map back to the original offsets, so a
    // match found in the folded text is reported in the original one. Folding is per code point, so a folded
    // character never straddles two original characters and the map is exact.

    private class Folded(val text: String, val origin: IntArray, private val originalLength: Int) {
        fun originEnd(foldedEnd: Int): Int = if (foldedEnd >= origin.size) originalLength else origin[foldedEnd]

        companion object {
            fun of(source: String, options: RichTextSearchOptions): Folded {
                val out = StringBuilder(source.length)
                val origin = ArrayList<Int>(source.length)
                var i = 0
                while (i < source.length) {
                    val cp = source.codePointAt(i)
                    val width = Character.charCount(cp)
                    // A combining mark of its own (decomposed text: "e" + U+0301) folds to nothing, so a
                    // decomposed accent matches like a precomposed one and the reported range extends over it.
                    if (!options.diacriticSensitive && isMark(cp)) {
                        i += width
                        continue
                    }
                    var piece = String(Character.toChars(cp))
                    if (!options.diacriticSensitive) {
                        piece = stripMarks(piece)
                    }
                    if (!options.caseSensitive) {
                        piece = piece.lowercase()
                    }
                    for (unit in piece) {
                        out.append(unit)
                        origin.add(i)
                    }
                    i += width
                }
                return Folded(out.toString(), origin.toIntArray(), source.length)
            }

            private fun isMark(cp: Int): Boolean {
                val type = Character.getType(cp)
                return type == Character.NON_SPACING_MARK.toInt() || type == Character.COMBINING_SPACING_MARK.toInt() ||
                    type == Character.ENCLOSING_MARK.toInt()
            }

            private fun stripMarks(s: String): String {
                val decomposed = Normalizer.normalize(s, Normalizer.Form.NFD)
                val kept = StringBuilder(decomposed.length)
                var i = 0
                while (i < decomposed.length) {
                    val cp = decomposed.codePointAt(i)
                    if (!isMark(cp)) kept.appendCodePoint(cp)
                    i += Character.charCount(cp)
                }
                return kept.toString()
            }
        }
    }

    private fun isWholeWord(range: RichTextRange, text: String): Boolean {
        if (range.start > 0 && isWordCharacter(text.codePointBefore(range.start))) return false
        if (range.end < text.length && isWordCharacter(text.codePointAt(range.end))) return false
        return true
    }

    private fun isWordCharacter(cp: Int): Boolean = Character.isLetterOrDigit(cp) || cp == '_'.code

    /**
     * The snippet and the match's range within it. Built by collapsing whitespace run by run while tracking where
     * the match's two ends land, so the returned inner range is exact.
     */
    private fun snippet(range: RichTextRange, text: String, context: Int): Pair<String, RichTextRange> {
        // Stay on the match's own line: a snippet that runs into the next paragraph reads as nonsense.
        val lineStart = if (range.start == 0) 0 else text.lastIndexOf('\n', range.start - 1).let { if (it < 0) 0 else it + 1 }
        // The line the match ENDS on, so a match crossing a newline is never cut (Swift: lineRange(for:)).
        val lineEndRaw = text.indexOf('\n', maxOf(range.start, range.end - 1))
        val lineEnd = if (lineEndRaw < 0) text.length else lineEndRaw
        var start = maxOf(lineStart, range.start - maxOf(0, context))
        var end = minOf(lineEnd, range.end + maxOf(0, context))
        // Do not cut a surrogate pair in half at either edge.
        if (start in 1 until text.length && Character.isLowSurrogate(text[start])) start -= 1
        if (end in 1 until text.length && Character.isLowSurrogate(text[end])) end += 1

        val leadingCut = start > lineStart
        val trailingCut = end < lineEnd && text.substring(end, lineEnd).isNotBlank()

        val out = StringBuilder()
        if (leadingCut) out.append("...")
        var matchStart = -1
        var matchEnd = -1
        var pendingSpace = false
        var index = start
        while (index < end) {
            if (index == range.start) matchStart = out.length + (if (pendingSpace) 1 else 0)
            if (index == range.end) matchEnd = out.length
            val unit = text[index]
            if (unit == '\uFFFC') {
                index++
                continue
            }
            if (unit.isWhitespace()) {
                pendingSpace = out.isNotEmpty() || leadingCut
                index++
                continue
            }
            if (pendingSpace) {
                out.append(' ')
                pendingSpace = false
            }
            out.append(unit)
            index++
        }
        if (matchEnd < 0) matchEnd = out.length
        if (trailingCut) out.append("...")
        val inner = if (matchStart >= 0 && matchEnd >= matchStart) RichTextRange(matchStart, matchEnd) else RichTextRange(0, 0)
        return out.toString() to inner
    }
}

/**
 * The document as the plain text a reader sees, for indexing and for searching many documents without rendering
 * any: blocks one per line, images as their alt text, table rows as comma-separated cells, code verbatim, no
 * Markdown syntax. The port of RichTextAccessibility.label(for:) - what a screen reader speaks, what an index
 * stores and what a find bar matches are one linearization.
 *
 * Ranges found in THIS text are not view ranges: search the rendered form ([RichTextSearch.matches] over a
 * document) when a range must be painted.
 */
object RichTextPlainText {
    fun text(document: RichTextDocument): String {
        val lines = mutableListOf<String>()
        append(document.blocks, lines)
        return lines.filter { it.isNotEmpty() }.joinToString("\n")
    }

    private fun append(blocks: List<RichTextBlock>, lines: MutableList<String>) {
        for (block in blocks) {
            when (block) {
                is RichTextBlock.Heading -> lines.add(block.inlines.plainText)
                is RichTextBlock.Paragraph -> lines.add(block.inlines.plainText)
                is RichTextBlock.CodeBlock -> lines.add(block.code.trim('\n', '\r'))
                is RichTextBlock.BlockQuote -> append(block.blocks, lines)
                is RichTextBlock.ListBlock -> for (item in block.items) append(item, lines)
                RichTextBlock.ThematicBreak -> Unit
                is RichTextBlock.Table -> {
                    lines.add(rowText(block.headers))
                    for (row in block.rows) lines.add(rowText(row))
                }
            }
        }
    }

    // One table row as "cell, cell, cell" so a screen reader announces columns distinctly.
    private fun rowText(cells: List<List<RichTextInline>>): String = cells.joinToString(", ") { it.plainText }
}
