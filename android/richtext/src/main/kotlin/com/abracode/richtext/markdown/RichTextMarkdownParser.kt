package com.abracode.richtext.markdown

import com.abracode.richtext.isMarkdownNumber
import com.abracode.richtext.isMarkdownWhitespace
import com.abracode.richtext.model.RichTextBlock
import com.abracode.richtext.model.RichTextColumnAlignment
import com.abracode.richtext.model.RichTextInline
import com.abracode.richtext.trimMarkdownWhitespace

// A small, dependency-free Markdown parser. A line-based block parser plus a recursive inline parser covering
// the subset a chat / document surface uses: ATX headings, paragraphs, fenced code, block quotes, ordered /
// unordered / nested lists, thematic breaks, GFM tables; inline **strong**, *emphasis*, ***both***, ~~strike~~,
// `code`, [links](url), <autolinks>, escapes, entities, hard breaks.
//
// Emphasis follows CommonMark's flanking rules, so a * or _ opens or closes only where CommonMark's would:
// snake_case_word and 2 * 3 * 4 stay literal, as they do in Apple's AttributedString(markdown:).
//
// The parser is TOTAL: malformed or INCOMPLETE input never throws and never loses text (an unterminated
// `**bold` renders as literal "**bold" until it closes). That property is what makes STREAMING safe. A 1:1
// semantic port of Sources/RichText/Markdown/RichTextMarkdownParser.swift - the function decomposition and names
// are kept parallel so future Swift fixes cross-port as a diff.
//
// Representation note: where the Swift inline parser and scanner operate over `[Character]` (grapheme clusters),
// this port operates over UTF-16 code units (`CharArray` / `String` indices). All structural delimiters are
// ASCII and text is reassembled losslessly, so the parsed output is identical for the supported dialect; only
// the internal chunking of non-ASCII text differs, which the model does not observe.

object RichTextMarkdownParser {

    // A mutable line cursor, standing in for Swift's `inout Int` index parameter.
    private class Cursor(var i: Int)

    fun parse(source: String): List<RichTextBlock> {
        val normalized = source
            .replace("\r\n", "\n")
            .replace("\r", "\n")
        val lines = normalized.split("\n")
        val (kept, references) = extractLinkReferences(lines)
        return parseBlocks(kept, references, 0)
    }

    // MARK: Link reference definitions

    // Pulls "[label]: url [optional title]" definition lines out of the document (they render nothing) and
    // returns the remaining lines plus a label -> url map used to resolve reference-style links. Lines inside a
    // fenced code block are left alone.
    private fun extractLinkReferences(lines: List<String>): Pair<List<String>, Map<String, String>> {
        val references = LinkedHashMap<String, String>()
        val kept = mutableListOf<String>()
        var inFence = false
        var fenceChar = '`'
        var fenceLength = 0
        for (line in lines) {
            val trimmed = line.trimMarkdownWhitespace()
            if (inFence) {
                kept.add(line)
                // Match parseFence's close rule: a closing fence is a line of only the fence char whose run is at
                // least as long as the opener. A shorter run (e.g. ``` inside a ```` block) stays code.
                if (trimmed.isNotEmpty() && trimmed.all { it == fenceChar } && trimmed.length >= fenceLength) {
                    inFence = false
                }
                continue
            }
            if (trimmed.startsWith("```") || trimmed.startsWith("~~~")) {
                inFence = true
                fenceChar = trimmed[0]
                fenceLength = trimmed.takeWhile { it == fenceChar }.length
                kept.add(line)
                continue
            }
            val definition = parseLinkReferenceDefinition(line)
            if (definition != null) {
                if (references[definition.first] == null) {
                    references[definition.first] = definition.second
                }
                continue   // drop the definition line
            }
            kept.add(line)
        }
        return kept to references
    }

    private fun parseLinkReferenceDefinition(line: String): Pair<String, String>? {
        val trimmed = line.trimMarkdownWhitespace()
        if (!trimmed.startsWith("[")) return null
        val close = trimmed.indexOf(']')
        if (close < 0) return null
        val afterClose = close + 1
        if (afterClose >= trimmed.length || trimmed[afterClose] != ':') return null
        val label = trimmed.substring(1, close).trimMarkdownWhitespace()
        if (label.isEmpty()) return null
        val rest = trimmed.substring(afterClose + 1).trimMarkdownWhitespace()
        if (rest.isEmpty()) return null
        var url = rest.substringBefore(' ')
        if (url.startsWith("<") && url.endsWith(">")) {
            url = url.substring(1, url.length - 1)
        }
        return label.lowercase() to url
    }

    // Nesting cap for block quotes / lists. Deep enough that real documents never reach it, shallow enough that
    // unbounded nesting (e.g. "> " repeated thousands of times) cannot recurse into a stack overflow.
    private const val MAX_BLOCK_DEPTH = 48

    private fun parseBlocks(lines: List<String>, references: Map<String, String>, depth: Int): List<RichTextBlock> {
        // Past the cap, stop descending into quotes / lists: emit the remaining lines as plain paragraphs so
        // nesting is bounded and no text is lost (the leftover markers just render literally).
        if (depth > MAX_BLOCK_DEPTH) {
            return flattenToParagraphs(lines, references)
        }
        val blocks = mutableListOf<RichTextBlock>()
        val cursor = Cursor(0)
        while (cursor.i < lines.size) {
            val line = lines[cursor.i]
            if (line.trimMarkdownWhitespace().isEmpty()) {
                cursor.i++
                continue
            }
            val fence = parseFence(lines, cursor)
            if (fence != null) {
                blocks.add(fence)
                continue
            }
            if (isThematicBreak(line)) {
                blocks.add(RichTextBlock.ThematicBreak)
                cursor.i++
                continue
            }
            val heading = parseHeading(line, references)
            if (heading != null) {
                blocks.add(heading)
                cursor.i++
                continue
            }
            if (isBlockQuote(line)) {
                blocks.add(parseBlockQuote(lines, cursor, references, depth))
                continue
            }
            val table = parseTable(lines, cursor, references)
            if (table != null) {
                blocks.add(table)
                continue
            }
            if (listItemMatch(line) != null) {
                blocks.add(parseList(lines, cursor, references, depth))
                continue
            }
            blocks.add(parseParagraph(lines, cursor, references))
        }
        return blocks
    }

    // Emits lines as plain paragraphs (blank lines separate them) without recursing into any nested-block
    // parsing. Used when the nesting cap is hit - preserves all text while bounding recursion.
    private fun flattenToParagraphs(lines: List<String>, references: Map<String, String>): List<RichTextBlock> {
        val blocks = mutableListOf<RichTextBlock>()
        val group = mutableListOf<String>()
        fun flush() {
            if (group.isNotEmpty()) {
                blocks.add(RichTextBlock.Paragraph(RichTextInlineParser.parse(joinParagraph(group), references)))
                group.clear()
            }
        }
        for (line in lines) {
            if (line.trimMarkdownWhitespace().isEmpty()) {
                flush()
            } else {
                group.add(line)
            }
        }
        flush()
        return blocks
    }

    // MARK: Fenced code

    private fun isFenceStartLine(line: String): Boolean {
        val t = line.trimMarkdownWhitespace()
        return t.startsWith("```") || t.startsWith("~~~")
    }

    private fun parseFence(lines: List<String>, cursor: Cursor): RichTextBlock? {
        val trimmed = lines[cursor.i].trimMarkdownWhitespace()
        val fenceChar: Char = when {
            trimmed.startsWith("```") -> '`'
            trimmed.startsWith("~~~") -> '~'
            else -> return null
        }
        val openLength = trimmed.takeWhile { it == fenceChar }.length
        if (openLength < 3) return null
        val info = trimmed.dropWhile { it == fenceChar }.trimMarkdownWhitespace()
        val language = if (info.isEmpty()) null else info.takeWhile { !it.isMarkdownWhitespace() }

        val codeLines = mutableListOf<String>()
        var j = cursor.i + 1
        while (j < lines.size) {
            val candidate = lines[j].trimMarkdownWhitespace()
            val isClose = candidate.isNotEmpty() &&
                candidate.all { it == fenceChar } &&
                candidate.length >= openLength
            if (isClose) {
                j++
                break
            }
            codeLines.add(lines[j])
            j++
        }
        cursor.i = j
        return RichTextBlock.CodeBlock(language, codeLines.joinToString("\n"))
    }

    // MARK: Headings / rules

    private fun parseHeading(line: String, references: Map<String, String> = emptyMap()): RichTextBlock? {
        val trimmed = line.dropWhile { it == ' ' }
        val level = trimmed.takeWhile { it == '#' }.length
        if (level < 1 || level > 6) return null
        val rest = trimmed.drop(level)
        val first = rest.firstOrNull()
        if (first != null && first != ' ') return null
        val content = stripClosingHashSequence(rest.trimMarkdownWhitespace())
        return RichTextBlock.Heading(level, RichTextInlineParser.parse(content, references))
    }

    // Strips a GFM ATX closing sequence: the trailing `\s+#+\s*$` the Swift reference removes with a regex. Done
    // as an explicit backward scan (not a regex) so it is O(1) in the no-match case and can never catastrophically
    // backtrack - a `Regex("\\s+#+\\s*$")` on a long interior-whitespace, no-'#' heading line (e.g.
    // "a" + " ".repeat(100_000) + "b") is O(n^2) in Java's engine, which would break the parser's totality /
    // streaming-safety guarantee. Semantically identical to the reference: the closing '#'s are only a closing
    // sequence when preceded by whitespace, so "# C#" keeps its '#'. Whitespace here is ICU's `\s`
    // (`[\t\n\f\r\p{Z}]`) - what the reference's NSRegularExpression uses.
    private fun stripClosingHashSequence(content: String): String {
        var end = content.length
        while (end > 0 && content[end - 1].isIcuWhitespace()) end--   // \s*$
        val hashEnd = end
        while (end > 0 && content[end - 1] == '#') end--             // #+
        if (end == hashEnd) return content                          // no '#' run -> not a closing sequence
        val wsEnd = end
        while (end > 0 && content[end - 1].isIcuWhitespace()) end--  // \s+ (required before the '#'s)
        if (end == wsEnd) return content                            // no whitespace before the '#'s ("# C#")
        return content.substring(0, end)
    }

    // ICU regex `\s` = [\t\n\f\r\p{Z}] (Zs + Zl + Zp), matching the Swift NSRegularExpression semantics.
    private fun Char.isIcuWhitespace(): Boolean = when (this) {
        '\t', '\n', '\u000C', '\r' -> true
        else -> when (Character.getType(this)) {
            Character.SPACE_SEPARATOR.toInt(),
            Character.LINE_SEPARATOR.toInt(),
            Character.PARAGRAPH_SEPARATOR.toInt() -> true
            else -> false
        }
    }

    private fun isThematicBreak(line: String): Boolean {
        val t = line.trimMarkdownWhitespace()
        if (t.length < 3) return false
        val distinct = t.filter { it != ' ' }.toSet()
        if (distinct.size != 1) return false
        val c = distinct.first()
        if (c != '-' && c != '*' && c != '_') return false
        return t.count { it == c } >= 3
    }

    // MARK: Block quote

    private fun isBlockQuote(line: String): Boolean = line.dropWhile { it == ' ' }.firstOrNull() == '>'

    private fun parseBlockQuote(lines: List<String>, cursor: Cursor, references: Map<String, String>, depth: Int): RichTextBlock {
        val inner = mutableListOf<String>()
        while (cursor.i < lines.size) {
            val stripped = lines[cursor.i].dropWhile { it == ' ' }
            if (stripped.firstOrNull() == '>') {
                var rest = stripped.drop(1)
                if (rest.firstOrNull() == ' ') {
                    rest = rest.drop(1)
                }
                inner.add(rest)
                cursor.i++
            } else {
                break
            }
        }
        return RichTextBlock.BlockQuote(parseBlocks(inner, references, depth + 1))
    }

    // MARK: Lists

    private class ListMarker(
        val ordered: Boolean,
        val start: Int,
        val indent: Int,
        val contentIndent: Int,
        val content: String,
    )

    private fun listItemMatch(line: String): ListMarker? {
        val indent = line.takeWhile { it == ' ' }.length
        val afterIndent = line.drop(indent)
        val first = afterIndent.firstOrNull() ?: return null

        if (first == '-' || first == '*' || first == '+') {
            val afterMarker = afterIndent.drop(1)
            if (afterMarker.firstOrNull() != ' ') return null
            val spaces = afterMarker.takeWhile { it == ' ' }.length
            val content = afterMarker.drop(spaces)
            return ListMarker(
                ordered = false, start = 1, indent = indent,
                contentIndent = indent + 1 + spaces, content = content,
            )
        }

        val digits = afterIndent.takeWhile { it.isMarkdownNumber() }
        if (digits.isNotEmpty()) {
            val afterDigits = afterIndent.drop(digits.length)
            val delim = afterDigits.firstOrNull()
            if (delim != '.' && delim != ')') return null
            val afterDelim = afterDigits.drop(1)
            if (afterDelim.firstOrNull() != ' ') return null
            val spaces = afterDelim.takeWhile { it == ' ' }.length
            val content = afterDelim.drop(spaces)
            return ListMarker(
                ordered = true, start = digits.toIntOrNull() ?: 1, indent = indent,
                contentIndent = indent + digits.length + 1 + spaces, content = content,
            )
        }

        return null
    }

    private fun parseList(lines: List<String>, cursor: Cursor, references: Map<String, String>, depth: Int): RichTextBlock {
        val first = listItemMatch(lines[cursor.i])!!
        val ordered = first.ordered
        val baseIndent = first.indent
        val items = mutableListOf<List<RichTextBlock>>()
        var loose = false

        while (cursor.i < lines.size) {
            val marker = listItemMatch(lines[cursor.i])
            if (marker == null || marker.indent != baseIndent || marker.ordered != ordered) {
                break
            }
            val contentIndent = marker.contentIndent
            val itemLines = mutableListOf(marker.content)
            cursor.i++

            while (cursor.i < lines.size) {
                val line = lines[cursor.i]
                if (line.trimMarkdownWhitespace().isEmpty()) {
                    val next = if (cursor.i + 1 < lines.size) lines[cursor.i + 1] else null
                    val continues = if (next != null) {
                        val lead = next.takeWhile { it == ' ' }.length
                        if (lead >= contentIndent) true else listItemMatch(next)?.indent == baseIndent
                    } else {
                        false
                    }
                    if (continues) {
                        loose = true
                        itemLines.add("")
                        cursor.i++
                        continue
                    }
                    break
                }
                val sibling = listItemMatch(line)
                if (sibling != null && sibling.indent == baseIndent) {
                    break
                }
                val lead = line.takeWhile { it == ' ' }.length
                if (lead >= contentIndent) {
                    itemLines.add(line.drop(contentIndent))
                    cursor.i++
                } else if ((listItemMatch(line)?.indent ?: -1) > baseIndent) {
                    itemLines.add(line.drop(minOf(contentIndent, lead)))
                    cursor.i++
                } else {
                    itemLines.add(line)
                    cursor.i++
                }
            }
            items.add(parseBlocks(itemLines, references, depth + 1))
        }

        return RichTextBlock.ListBlock(ordered = ordered, start = first.start, tight = !loose, items = items)
    }

    // MARK: Tables (GFM)

    private fun parseTable(lines: List<String>, cursor: Cursor, references: Map<String, String>): RichTextBlock? {
        if (!lines[cursor.i].contains("|") || cursor.i + 1 >= lines.size || !isTableDelimiter(lines[cursor.i + 1])) {
            return null
        }
        val headers = splitTableRow(lines[cursor.i]).map { RichTextInlineParser.parse(it, references) }
        val alignments = parseAlignments(lines[cursor.i + 1])
        val rows = mutableListOf<List<List<RichTextInline>>>()
        var j = cursor.i + 2
        while (j < lines.size) {
            val line = lines[j]
            if (line.trimMarkdownWhitespace().isEmpty() || !line.contains("|")) {
                break
            }
            rows.add(splitTableRow(line).map { RichTextInlineParser.parse(it, references) })
            j++
        }
        cursor.i = j
        return RichTextBlock.Table(headers = headers, alignments = alignments, rows = rows)
    }

    private fun isTableDelimiter(line: String): Boolean {
        val t = line.trimMarkdownWhitespace()
        if (!t.contains("-") || !t.contains("|")) return false
        for (c in t) {
            if (c != '|' && c != ':' && c != '-' && c != ' ') return false
        }
        return true
    }

    private fun splitTableRow(line: String): List<String> {
        var t = line.trimMarkdownWhitespace()
        if (t.startsWith("|")) t = t.substring(1)
        if (t.endsWith("|")) t = t.substring(0, t.length - 1)
        return t.split("|").map { it.trimMarkdownWhitespace() }
    }

    private fun parseAlignments(line: String): List<RichTextColumnAlignment> =
        splitTableRow(line).map { cell ->
            val left = cell.startsWith(":")
            val right = cell.endsWith(":")
            when {
                left && right -> RichTextColumnAlignment.CENTER
                right -> RichTextColumnAlignment.RIGHT
                left -> RichTextColumnAlignment.LEFT
                else -> RichTextColumnAlignment.NONE
            }
        }

    // MARK: Paragraph

    private fun parseParagraph(lines: List<String>, cursor: Cursor, references: Map<String, String>): RichTextBlock {
        val collected = mutableListOf<String>()
        while (cursor.i < lines.size) {
            val line = lines[cursor.i]
            if (line.trimMarkdownWhitespace().isEmpty()) break
            if (isThematicBreak(line) || isFenceStartLine(line) || isBlockQuote(line) ||
                parseHeading(line) != null || listItemMatch(line) != null
            ) {
                break
            }
            if (line.contains("|") && cursor.i + 1 < lines.size && isTableDelimiter(lines[cursor.i + 1])) {
                break
            }
            collected.add(line)
            cursor.i++
        }
        return RichTextBlock.Paragraph(RichTextInlineParser.parse(joinParagraph(collected), references))
    }

    private fun joinParagraph(lines: List<String>): String {
        val result = StringBuilder()
        for ((index, raw) in lines.withIndex()) {
            val hardBreak = raw.endsWith("  ") || raw.endsWith("\\")
            var line = raw.trimEnd(' ')
            if (hardBreak && line.endsWith("\\")) {
                line = line.dropLast(1)
            }
            result.append(line)
            if (index < lines.size - 1) {
                result.append(if (hardBreak) "\u2028" else " ")
            }
        }
        return result.toString()
    }
}

// MARK: - Inline parser

private class RichTextInlineParser private constructor(text: String, private val references: Map<String, String>) {
    private val chars: CharArray = text.toCharArray()
    private var pos = 0

    // Precomputed last index of ']' / ')' (or -1). Lets a link/image bail out in O(1) when no closing delimiter
    // exists ahead - without it an unbalanced run like "[[[[..." makes every failed parse scan to end-of-input,
    // which combined with the retry-by-one caller is catastrophic (O(2^n) / polynomial).
    private val lastCloseBracket: Int = chars.lastIndexOf(']')
    private val lastCloseParen: Int = chars.lastIndexOf(')')

    // Where an opener of each marker run ("*", "**", "_", "~~"...) first searched to the end of its scope (the
    // text, or the link text it is in) without finding its closer: a later opener of the same run in that scope
    // finds none either, so it stays literal at once. Without it, openers that cannot close each other (a long
    // run of "*" or "_") nest attempts inside attempts and the parse takes exponential time. parseLink gives the
    // link text a scope of its own.
    private var unclosedFrom = mutableMapOf<String, Int>()
    // Openers that found their closer: the failed search of an earlier opener ran past them, so they lie after
    // its unclosedFrom entry, yet their own search succeeds ("*a *b* c": *b* still emphasizes).
    private val closedAt = HashSet<Int>()
    // The marker run measured last: each position in a long run asks for the same run, and measuring it anew every
    // time made a run of n markers take n * n steps.
    private var lastRun: IntRange = IntRange.EMPTY

    private class Runs(val nodes: List<RichTextInline>, val matched: Boolean)

    companion object {
        // Recursion-depth cap for the structural helpers. Real inline nesting never approaches this; past it
        // markup characters are emitted literally so a crafted deep/unbalanced nest cannot blow the stack.
        private const val MAX_DEPTH = 32

        // The characters a backslash may escape (Swift: "\\`*_{}[]()#+-.!~>|\"<&").
        private const val ESCAPABLE = "\\`*_{}[]()#+-.!~>|\"<&"

        // ASCII punctuation for the flanking rules (with Unicode punctuation, isFlankingPunctuation).
        private const val ASCII_PUNCTUATION = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"

        // The named entities decoded: the common ones. Others stay literal.
        private val NAMED_ENTITIES: Map<String, String> = mapOf(
            "amp" to "&", "lt" to "<", "gt" to ">", "quot" to "\"", "apos" to "'", "nbsp" to "\u00A0",
            "copy" to "\u00A9", "reg" to "\u00AE", "trade" to "\u2122", "hellip" to "\u2026",
            "mdash" to "\u2014", "ndash" to "\u2013", "lsquo" to "\u2018", "rsquo" to "\u2019",
            "ldquo" to "\u201C", "rdquo" to "\u201D", "laquo" to "\u00AB", "raquo" to "\u00BB",
            "bull" to "\u2022", "middot" to "\u00B7", "deg" to "\u00B0", "plusmn" to "\u00B1",
            "times" to "\u00D7", "divide" to "\u00F7", "euro" to "\u20AC", "pound" to "\u00A3",
            "yen" to "\u00A5", "cent" to "\u00A2", "sect" to "\u00A7", "para" to "\u00B6",
            "larr" to "\u2190", "rarr" to "\u2192", "uarr" to "\u2191", "darr" to "\u2193",
            "harr" to "\u2194", "ne" to "\u2260", "le" to "\u2264", "ge" to "\u2265",
        )

        // Whitespace for flanking: the start and end of the text count as whitespace, as do line breaks.
        private fun isFlankingWhitespace(c: Char?): Boolean = c == null || c.isWhitespace()

        // ASCII punctuation, or a Unicode punctuation character (general category P*).
        private fun isFlankingPunctuation(c: Char?): Boolean {
            if (c == null) return false
            if (c in ASCII_PUNCTUATION) return true
            return when (Character.getType(c).toByte()) {
                Character.CONNECTOR_PUNCTUATION, Character.DASH_PUNCTUATION, Character.START_PUNCTUATION,
                Character.END_PUNCTUATION, Character.INITIAL_QUOTE_PUNCTUATION, Character.FINAL_QUOTE_PUNCTUATION,
                Character.OTHER_PUNCTUATION -> true
                else -> false
            }
        }

        private fun Char.isAsciiLetter(): Boolean = this in 'a'..'z' || this in 'A'..'Z'
        private fun Char.isAsciiLetterOrDigit(): Boolean = isAsciiLetter() || this in '0'..'9'

        // A scheme of 2 to 32 letters, digits, + . or - (starting with a letter), a colon, and the rest.
        private fun isAutolinkURI(s: String): Boolean {
            val colon = s.indexOf(':')
            if (colon < 0) return false
            val scheme = s.substring(0, colon)
            if (scheme.length !in 2..32 || !scheme[0].isAsciiLetter()) return false
            return scheme.all { it.isAsciiLetterOrDigit() || it == '+' || it == '.' || it == '-' }
        }

        // user@host.domain: the local part of letters, digits and .!#$%&'*+/=?^_`{|}~-, the host of labels of
        // letters, digits and hyphens.
        private fun isAutolinkEmail(s: String): Boolean {
            val parts = s.split("@")
            if (parts.size != 2 || parts[0].isEmpty() || parts[1].isEmpty()) return false
            val localAllowed = ".!#$%&'*+/=?^_`{|}~-"
            if (!parts[0].all { it.isAsciiLetterOrDigit() || it in localAllowed }) return false
            return parts[1].split(".").all { label ->
                label.isNotEmpty() && label.length <= 63 && label.first() != '-' && label.last() != '-' &&
                    label.all { it.isAsciiLetterOrDigit() || it == '-' }
            }
        }

        // The destination inside (...): <with spaces> (spaces as %20, as Apple's parser gives them), else up to
        // the first whitespace; a title after it ("Title", 'Title', (Title)) is left out.
        private fun linkDestination(raw: String): String {
            val trimmed = raw.trimMarkdownWhitespace()
            if (trimmed.startsWith("<")) {
                val close = trimmed.indexOf('>')
                if (close >= 0) {
                    return trimmed.substring(1, close).replace(" ", "%20")
                }
            }
            return trimmed.takeWhile { !it.isWhitespace() }
        }

        fun parse(text: String, references: Map<String, String> = emptyMap()): List<RichTextInline> {
            val parser = RichTextInlineParser(text, references)
            return RichTextAutolinker.link(parser.parseRuns(null, 0).nodes)
        }
    }

    // `inLink`: the runs are inside link text, where a span opened there must also close there.
    private fun parseRuns(stop: String?, depth: Int, inLink: Boolean = false): Runs {
        val nodes = mutableListOf<RichTextInline>()
        val buffer = StringBuilder()
        // Past the cap, stop treating markup as structural: emit it literally (advance by one). No text is lost -
        // everything becomes plain text - and recursion is bounded.
        val allowStructural = depth <= MAX_DEPTH

        fun flush() {
            if (buffer.isNotEmpty()) {
                nodes.add(RichTextInline.Text(buffer.toString()))
                buffer.setLength(0)
            }
        }

        while (pos < chars.size) {
            if (stop != null && matches(stop, pos) && isCloser(stop, pos)) {
                pos += stop.length
                flush()
                return Runs(nodes, true)
            }
            // The ']' ending the link text ends a span opened inside it unclosed, as in CommonMark: "[*a](u) b*"
            // is a link "*a", not emphasis reaching out of the brackets.
            if (inLink && chars[pos] == ']') {
                flush()
                return Runs(nodes, false)
            }

            when (val c = chars[pos]) {
                '\\' -> {
                    if (pos + 1 < chars.size && isEscapable(chars[pos + 1])) {
                        buffer.append(chars[pos + 1])
                        pos += 2
                    } else {
                        buffer.append(c)
                        pos += 1
                    }
                }
                '\u2028' -> {
                    flush()
                    nodes.add(RichTextInline.LineBreak)
                    pos += 1
                }
                '`' -> {
                    val node = if (allowStructural) parseCodeSpan() else null
                    if (node != null) {
                        flush()
                        nodes.add(node)
                    } else {
                        buffer.append(c)
                        pos += 1
                    }
                }
                '*', '_', '~' -> {
                    val node = if (allowStructural) parseEmphasis(c, depth, inLink) else null
                    if (node != null) {
                        flush()
                        nodes.add(node)
                    } else {
                        buffer.append(c)
                        pos += 1
                    }
                }
                '!' -> {
                    val node = if (allowStructural) parseImage() else null
                    if (node != null) {
                        flush()
                        nodes.add(node)
                    } else {
                        buffer.append(c)
                        pos += 1
                    }
                }
                '[' -> {
                    val link = if (allowStructural) parseLink(depth) else null
                    if (link != null) {
                        flush()
                        nodes.addAll(link)
                    } else {
                        buffer.append(c)
                        pos += 1
                    }
                }
                '<' -> {
                    val node = if (allowStructural) parseAngleAutolink() else null
                    if (node != null) {
                        flush()
                        nodes.add(node)
                    } else {
                        buffer.append(c)
                        pos += 1
                    }
                }
                '&' -> {
                    val decoded = parseEntity()
                    if (decoded != null) {
                        buffer.append(decoded)
                    } else {
                        buffer.append(c)
                        pos += 1
                    }
                }
                else -> {
                    buffer.append(c)
                    pos += 1
                }
            }
        }

        flush()
        return Runs(nodes, false)
    }

    private fun matches(s: String, index: Int): Boolean {
        if (index + s.length > chars.size) return false
        for (k in s.indices) {
            if (chars[index + k] != s[k]) return false
        }
        return true
    }

    private fun isEscapable(c: Char): Boolean = c in ESCAPABLE

    // MARK: Flanking (CommonMark 0.29, "left-flanking delimiter run")

    private fun charAt(index: Int): Char? = if (index >= 0 && index < chars.size) chars[index] else null

    // The whole run of `marker` around `index`, so a run is judged as one, as CommonMark does.
    private fun runAround(marker: Char, index: Int): IntRange {
        if (index in lastRun && chars[index] == marker) return lastRun
        var start = index
        while (start > 0 && chars[start - 1] == marker) start -= 1
        var end = index
        while (end < chars.size && chars[end] == marker) end += 1
        lastRun = start until end
        return lastRun
    }

    private class Flanking(val left: Boolean, val right: Boolean, val before: Char?, val after: Char?)

    private fun flanking(run: IntRange): Flanking {
        val before = charAt(run.first - 1)
        val after = charAt(run.last + 1)
        val left = !isFlankingWhitespace(after) &&
            (!isFlankingPunctuation(after) || isFlankingWhitespace(before) || isFlankingPunctuation(before))
        val right = !isFlankingWhitespace(before) &&
            (!isFlankingPunctuation(before) || isFlankingWhitespace(after) || isFlankingPunctuation(after))
        return Flanking(left, right, before, after)
    }

    // Whether the run of `marker` at `index` can open emphasis: `*` when left-flanking; `_` also not inside a
    // word (snake_case_word).
    private fun canOpen(marker: Char, index: Int): Boolean {
        val f = flanking(runAround(marker, index))
        return if (marker == '_') f.left && (!f.right || isFlankingPunctuation(f.before)) else f.left
    }

    // Whether the run of `marker` at `index` can close emphasis: `*` when right-flanking; `_` also not inside a
    // word.
    private fun canClose(marker: Char, index: Int): Boolean {
        val f = flanking(runAround(marker, index))
        return if (marker == '_') f.right && (!f.left || isFlankingPunctuation(f.after)) else f.right
    }

    // A stop closes the runs it ends: an emphasis stop only where its run can close.
    private fun isCloser(stop: String, index: Int): Boolean {
        val marker = stop.firstOrNull() ?: return true
        if (marker != '*' && marker != '_') return true
        return canClose(marker, index)
    }

    // MARK: Entities

    // &name; (a common named entity), &#123; or &#x1F600; at pos: its text, pos past it; null when there is none
    // (the & is literal).
    private fun parseEntity(): String? {
        var j = pos + 1
        val body = StringBuilder()
        while (j < chars.size && chars[j] != ';' && body.length < 32) {
            body.append(chars[j])
            j += 1
        }
        if (!(j < chars.size && chars[j] == ';') || body.isEmpty()) return null
        val name = body.toString()
        var decoded: String? = null
        if (name.startsWith("#")) {
            val digits = name.substring(1)
            val hex = digits.startsWith("x") || digits.startsWith("X")
            val number = if (hex) digits.substring(1) else digits
            val maxDigits = if (hex) 6 else 7
            val radix = if (hex) 16 else 10
            // ASCII digits only: Character.digit and toInt would also take other scripts' digits.
            val isDigit: (Char) -> Boolean = { it in '0'..'9' || (hex && (it in 'a'..'f' || it in 'A'..'F')) }
            if (number.isNotEmpty() && number.length <= maxDigits && number.all(isDigit)) {
                val value = number.toInt(radix)
                val valid = value != 0 && value <= 0x10FFFF && value !in 0xD800..0xDFFF
                decoded = if (valid) String(Character.toChars(value)) else "\uFFFD"
            }
        } else if (name.all { it.isAsciiLetterOrDigit() }) {
            decoded = NAMED_ENTITIES[name]
        }
        if (decoded == null) return null
        pos = j + 1
        return decoded
    }

    // MARK: Autolinks

    // <scheme:...> or <user@host> at pos: a link showing the address (mailto: for an email); null when the
    // brackets hold neither (HTML, "a < b > c").
    private fun parseAngleAutolink(): RichTextInline? {
        var j = pos + 1
        val content = StringBuilder()
        while (j < chars.size && chars[j] != '>') {
            val c = chars[j]
            if (c == '<' || c.isWhitespace()) return null
            content.append(c)
            j += 1
        }
        if (j >= chars.size || content.isEmpty()) return null
        val text = content.toString()
        val url = when {
            isAutolinkURI(text) -> text
            isAutolinkEmail(text) -> "mailto:$text"
            else -> return null
        }
        pos = j + 1
        return RichTextInline.Link(listOf(RichTextInline.Text(text)), url)
    }

    // ![alt](url) - the alt text is taken literally (image alt is plain text).
    private fun parseImage(): RichTextInline? {
        val start = pos
        if (!(pos + 1 < chars.size && chars[pos + 1] == '[')) return null
        pos += 2   // consume '!['
        if (pos > lastCloseBracket) {   // no ']' ahead: alt text can never close - bail before scanning
            pos = start
            return null
        }
        val alt = StringBuilder()
        while (pos < chars.size && chars[pos] != ']') {
            alt.append(chars[pos])
            pos += 1
        }
        if (!(pos < chars.size && chars[pos] == ']' && pos + 1 < chars.size && chars[pos + 1] == '(')) {
            pos = start
            return null
        }
        pos += 2   // consume ']('
        if (pos > lastCloseParen) {   // no ')' ahead: url can never close - bail before scanning
            pos = start
            return null
        }
        val url = StringBuilder()
        var depth = 1
        while (pos < chars.size) {
            when (val c = chars[pos]) {
                '(' -> {
                    depth += 1
                    url.append(c)
                    pos += 1
                }
                ')' -> {
                    depth -= 1
                    if (depth == 0) {
                        pos += 1
                        return RichTextInline.Image(alt.toString(), linkDestination(url.toString()))
                    }
                    url.append(c)
                    pos += 1
                }
                else -> {
                    url.append(c)
                    pos += 1
                }
            }
        }
        pos = start
        return null
    }

    private fun parseCodeSpan(): RichTextInline? {
        val start = pos
        var ticks = 0
        while (pos < chars.size && chars[pos] == '`') {
            ticks += 1
            pos += 1
        }
        var j = pos
        while (j < chars.size) {
            if (chars[j] != '`') {
                j += 1
                continue
            }
            var run = 0
            var k = j
            while (k < chars.size && chars[k] == '`') {
                run += 1
                k += 1
            }
            if (run == ticks) {
                val content = String(chars, pos, j - pos)
                pos = k
                return RichTextInline.Code(trimCodeSpan(content))
            }
            j = k
        }
        pos = start
        return null
    }

    private fun trimCodeSpan(s: String): String {
        if (s.length >= 2 && s.first() == ' ' && s.last() == ' ' && s.any { it != ' ' }) {
            return s.substring(1, s.length - 1)
        }
        return s
    }

    // Whether an opener at `start` that searches for `closer` is already known to find none.
    private fun knownUnclosed(closer: String, start: Int): Boolean =
        start >= (unclosedFrom[closer] ?: Int.MAX_VALUE) && start !in closedAt

    // Records the outcome of the search for `closer` from the opener at `start`. A success is kept only where the
    // search parsed structure (below the depth cap), so a cap artifact is not trusted later.
    private fun record(closer: String, start: Int, matched: Boolean, depth: Int) {
        if (matched) {
            if (depth + 1 <= MAX_DEPTH) {
                closedAt.add(start)
            }
        } else {
            closedAt.remove(start)
            unclosedFrom[closer] = minOf(unclosedFrom[closer] ?: Int.MAX_VALUE, start)
        }
    }

    private fun parseEmphasis(marker: Char, depth: Int, inLink: Boolean): RichTextInline? {
        val start = pos
        val run = runAround(marker, start).last + 1 - start

        if (marker == '~') {
            if (run < 2 || knownUnclosed("~~", start)) {
                pos = start
                return null
            }
            pos = start + 2
            val inner = parseRuns("~~", depth + 1, inLink)
            record("~~", start, inner.matched, depth)
            if (inner.matched) {
                return RichTextInline.Strikethrough(inner.nodes)
            }
            pos = start
            return null
        }

        // A run that cannot open (snake_case_word, 2 * 3 * 4) stays literal.
        if (!canOpen(marker, start)) {
            pos = start
            return null
        }
        val level = minOf(run, 3)
        val closer = marker.toString().repeat(level)
        if (knownUnclosed(closer, start)) {
            pos = start
            return null
        }
        pos = start + level
        val inner = parseRuns(closer, depth + 1, inLink)
        record(closer, start, inner.matched, depth)
        if (inner.matched) {
            return when (level) {
                1 -> RichTextInline.Emphasis(inner.nodes)
                2 -> RichTextInline.Strong(inner.nodes)
                else -> RichTextInline.Strong(listOf(RichTextInline.Emphasis(inner.nodes)))
            }
        }
        pos = start
        return null
    }

    // [text](url), [text][ref], [text][] or [ref] at pos: the link; or, for an empty destination ([text]()), its
    // text alone, as Apple's parser shows it. null when it is no link.
    private fun parseLink(depth: Int): List<RichTextInline>? {
        val start = pos
        pos += 1                              // consume '['
        if (pos > lastCloseBracket) {         // no ']' ahead: not a link in any form - bail in O(1)
            pos = start
            return null
        }
        val labelStart = pos
        // The link text is a scope of its own for unclosedFrom: a span opened in it ends at its ']'.
        val outerUnclosed = unclosedFrom
        unclosedFrom = mutableMapOf()
        val text = parseRuns("]", depth + 1, inLink = true)
        unclosedFrom = outerUnclosed
        if (!text.matched) {
            pos = start
            return null
        }
        val labelString = String(chars, labelStart, (pos - 1) - labelStart)   // raw label ('pos' is past the ']')

        // Inline link: [text](url)
        if (pos < chars.size && chars[pos] == '(') {
            if (pos + 1 > lastCloseParen) {   // no ')' ahead: url can never close - bail before scanning
                pos = start
                return null
            }
            pos += 1
            val url = StringBuilder()
            var parenDepth = 1
            while (pos < chars.size) {
                when (val c = chars[pos]) {
                    '(' -> {
                        parenDepth += 1
                        url.append(c)
                        pos += 1
                    }
                    ')' -> {
                        parenDepth -= 1
                        if (parenDepth == 0) {
                            pos += 1
                            val destination = linkDestination(url.toString())
                            return if (destination.isEmpty()) text.nodes else listOf(RichTextInline.Link(text.nodes, destination))
                        }
                        url.append(c)
                        pos += 1
                    }
                    else -> {
                        url.append(c)
                        pos += 1
                    }
                }
            }
            pos = start
            return null
        }

        // Reference link: [text][ref] or [text][] (collapsed, reuse the text as the label).
        if (pos < chars.size && chars[pos] == '[') {
            var j = pos + 1
            while (j < chars.size && chars[j] != ']') {
                j += 1
            }
            if (j < chars.size) {
                val refLabel = String(chars, pos + 1, j - (pos + 1)).trimMarkdownWhitespace()
                val key = (if (refLabel.isEmpty()) labelString else refLabel).lowercase()
                val url = references[key]
                if (url != null) {
                    pos = j + 1
                    return listOf(RichTextInline.Link(text.nodes, url))
                }
            }
            pos = start
            return null
        }

        // Shortcut reference: [ref] - only a link when 'ref' is a defined label (else falls through to literal,
        // so documents without reference definitions are unaffected).
        val url = references[labelString.lowercase()]
        if (url != null) {
            return listOf(RichTextInline.Link(text.nodes, url))
        }

        pos = start
        return null
    }
}
