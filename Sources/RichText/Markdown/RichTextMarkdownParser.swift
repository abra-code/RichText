// Sources/RichText/Markdown/RichTextMarkdownParser.swift
//
// A small, dependency-free Markdown parser - one convenient way to build a RichTextDocument. It is a
// line-based block parser plus a recursive inline parser covering the subset a chat / document surface
// uses: ATX headings, paragraphs, fenced code, block quotes, ordered / unordered / nested lists,
// thematic breaks, GFM tables; inline **strong**, *emphasis*, ***both***, ~~strike~~, `code`,
// [links](url), <autolinks>, escapes, entities, hard breaks.
//
// Emphasis follows CommonMark's flanking rules, so a * or _ opens or closes only where CommonMark's
// would: snake_case_word and 2 * 3 * 4 stay literal, as they do in Apple's AttributedString(markdown:).
//
// The parser is TOTAL: malformed or INCOMPLETE input never throws and never loses text (an unterminated
// `**bold` renders as literal "**bold" until it closes). That property is what makes STREAMING safe.

import Foundation

public extension RichTextDocument {
    /// Builds a document by parsing a Markdown string.
    init(markdown: String) {
        self.init(blocks: RichTextMarkdownParser.parse(markdown))
    }
}

public enum RichTextMarkdownParser {

    public static func parse(_ source: String) -> [RichTextBlock] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        let references = extractLinkReferences(&lines)
        return parseBlocks(lines, references: references)
    }

    // MARK: Link reference definitions

    // Pulls "[label]: url [optional title]" definition lines out of the document (they render nothing) and
    // returns a label -> url map used to resolve reference-style links. Lines inside a fenced code block
    // are left alone.
    private static func extractLinkReferences(_ lines: inout [String]) -> [String: String] {
        var references: [String: String] = [:]
        var kept: [String] = []
        var inFence = false
        var fenceChar: Character = "`"
        var fenceLength = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inFence {
                kept.append(line)
                // Match parseFence's close rule: a closing fence is a line of only the fence char whose run
                // is at least as long as the opener. A shorter run (e.g. ``` inside a ```` block) stays code.
                if !trimmed.isEmpty, trimmed.allSatisfy({ $0 == fenceChar }), trimmed.count >= fenceLength {
                    inFence = false
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence = true
                fenceChar = trimmed.first!
                fenceLength = trimmed.prefix(while: { $0 == fenceChar }).count
                kept.append(line)
                continue
            }
            if let definition = parseLinkReferenceDefinition(line) {
                if references[definition.label] == nil {
                    references[definition.label] = definition.url
                }
                continue   // drop the definition line
            }
            kept.append(line)
        }
        lines = kept
        return references
    }

    private static func parseLinkReferenceDefinition(_ line: String) -> (label: String, url: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else {
            return nil
        }
        let afterClose = trimmed.index(after: close)
        guard afterClose < trimmed.endIndex, trimmed[afterClose] == ":" else {
            return nil
        }
        let label = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else {
            return nil
        }
        let rest = String(trimmed[trimmed.index(after: afterClose)...]).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else {
            return nil
        }
        var url = rest.split(separator: " ", maxSplits: 1).first.map(String.init) ?? rest
        if url.hasPrefix("<"), url.hasSuffix(">") {
            url = String(url.dropFirst().dropLast())
        }
        return (label.lowercased(), url)
    }

    // Nesting cap for block quotes / lists. Deep enough that real documents never reach it, shallow enough
    // that unbounded nesting (e.g. "> " repeated thousands of times) cannot recurse into a stack overflow.
    private static let maxBlockDepth = 48

    static func parseBlocks(_ lines: [String], references: [String: String] = [:], depth: Int = 0) -> [RichTextBlock] {
        // Past the cap, stop descending into quotes / lists: emit the remaining lines as plain paragraphs so
        // nesting is bounded and no text is lost (the leftover markers just render literally).
        if depth > maxBlockDepth {
            return flattenToParagraphs(lines, references: references)
        }
        var blocks: [RichTextBlock] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
                continue
            }
            if let fence = parseFence(lines, &i) {
                blocks.append(fence)
                continue
            }
            if isThematicBreak(line) {
                blocks.append(.thematicBreak)
                i += 1
                continue
            }
            if let heading = parseHeading(line, references: references) {
                blocks.append(heading)
                i += 1
                continue
            }
            if isBlockQuote(line) {
                blocks.append(parseBlockQuote(lines, &i, references: references, depth: depth))
                continue
            }
            if let table = parseTable(lines, &i, references: references) {
                blocks.append(table)
                continue
            }
            if listItemMatch(line) != nil {
                blocks.append(parseList(lines, &i, references: references, depth: depth))
                continue
            }
            blocks.append(parseParagraph(lines, &i, references: references))
        }
        return blocks
    }

    // Emits lines as plain paragraphs (blank lines separate them) without recursing into any nested-block
    // parsing. Used when the nesting cap is hit - preserves all text while bounding recursion.
    private static func flattenToParagraphs(_ lines: [String], references: [String: String]) -> [RichTextBlock] {
        var blocks: [RichTextBlock] = []
        var group: [String] = []
        func flush() {
            if !group.isEmpty {
                blocks.append(.paragraph(RichTextInlineParser.parse(joinParagraph(group), references: references)))
                group.removeAll()
            }
        }
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else {
                group.append(line)
            }
        }
        flush()
        return blocks
    }

    // MARK: Fenced code

    private static func isFenceStartLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("```") || t.hasPrefix("~~~")
    }

    private static func parseFence(_ lines: [String], _ i: inout Int) -> RichTextBlock? {
        let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
        let fenceChar: Character
        if trimmed.hasPrefix("```") {
            fenceChar = "`"
        } else if trimmed.hasPrefix("~~~") {
            fenceChar = "~"
        } else {
            return nil
        }
        let openLength = trimmed.prefix(while: { $0 == fenceChar }).count
        if openLength < 3 {
            return nil
        }
        let info = String(trimmed.drop(while: { $0 == fenceChar })).trimmingCharacters(in: .whitespaces)
        let language = info.isEmpty ? nil : info.components(separatedBy: .whitespaces).first

        var codeLines: [String] = []
        var j = i + 1
        while j < lines.count {
            let candidate = lines[j].trimmingCharacters(in: .whitespaces)
            let isClose = !candidate.isEmpty
                && candidate.allSatisfy({ $0 == fenceChar })
                && candidate.count >= openLength
            if isClose {
                j += 1
                break
            }
            codeLines.append(lines[j])
            j += 1
        }
        i = j
        return .codeBlock(language: language, code: codeLines.joined(separator: "\n"))
    }

    // MARK: Headings / rules

    private static func parseHeading(_ line: String, references: [String: String] = [:]) -> RichTextBlock? {
        let trimmed = line.drop(while: { $0 == " " })
        let level = trimmed.prefix(while: { $0 == "#" }).count
        if level < 1 || level > 6 {
            return nil
        }
        let rest = trimmed.dropFirst(level)
        if let first = rest.first, first != " " {
            return nil
        }
        var content = rest.trimmingCharacters(in: .whitespaces)
        // A GFM ATX closing sequence is only a closing sequence when preceded by whitespace, so require a
        // space before the trailing '#'s. Without this "# C#" would wrongly strip the '#' from "C#".
        content = content.replacingOccurrences(of: "\\s+#+\\s*$", with: "", options: .regularExpression)
        return .heading(level: level, RichTextInlineParser.parse(content, references: references))
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.count < 3 {
            return false
        }
        let distinct = Set(t.filter { $0 != " " })
        guard distinct.count == 1, let c = distinct.first, c == "-" || c == "*" || c == "_" else {
            return false
        }
        return t.filter({ $0 == c }).count >= 3
    }

    // MARK: Block quote

    private static func isBlockQuote(_ line: String) -> Bool {
        return line.drop(while: { $0 == " " }).first == ">"
    }

    private static func parseBlockQuote(_ lines: [String], _ i: inout Int, references: [String: String] = [:], depth: Int = 0) -> RichTextBlock {
        var inner: [String] = []
        while i < lines.count {
            let stripped = lines[i].drop(while: { $0 == " " })
            if stripped.first == ">" {
                var rest = stripped.dropFirst()
                if rest.first == " " {
                    rest = rest.dropFirst()
                }
                inner.append(String(rest))
                i += 1
            } else {
                break
            }
        }
        return .blockQuote(parseBlocks(inner, references: references, depth: depth + 1))
    }

    // MARK: Lists

    private struct ListMarker {
        let ordered: Bool
        let start: Int
        let indent: Int
        let contentIndent: Int
        let content: String
    }

    private static func listItemMatch(_ line: String) -> ListMarker? {
        let indent = line.prefix(while: { $0 == " " }).count
        let afterIndent = line.dropFirst(indent)
        guard let first = afterIndent.first else {
            return nil
        }

        if first == "-" || first == "*" || first == "+" {
            let afterMarker = afterIndent.dropFirst()
            guard afterMarker.first == " " else {
                return nil
            }
            let spaces = afterMarker.prefix(while: { $0 == " " }).count
            let content = String(afterMarker.dropFirst(spaces))
            return ListMarker(ordered: false, start: 1, indent: indent,
                              contentIndent: indent + 1 + spaces, content: content)
        }

        let digits = afterIndent.prefix(while: { $0.isNumber })
        if !digits.isEmpty {
            let afterDigits = afterIndent.dropFirst(digits.count)
            guard let delim = afterDigits.first, delim == "." || delim == ")" else {
                return nil
            }
            let afterDelim = afterDigits.dropFirst()
            guard afterDelim.first == " " else {
                return nil
            }
            let spaces = afterDelim.prefix(while: { $0 == " " }).count
            let content = String(afterDelim.dropFirst(spaces))
            return ListMarker(ordered: true, start: Int(digits) ?? 1, indent: indent,
                              contentIndent: indent + digits.count + 1 + spaces, content: content)
        }

        return nil
    }

    private static func parseList(_ lines: [String], _ i: inout Int, references: [String: String] = [:], depth: Int = 0) -> RichTextBlock {
        let first = listItemMatch(lines[i])!
        let ordered = first.ordered
        let baseIndent = first.indent
        var items: [[RichTextBlock]] = []
        var loose = false

        while i < lines.count {
            guard let marker = listItemMatch(lines[i]),
                  marker.indent == baseIndent,
                  marker.ordered == ordered else {
                break
            }
            let contentIndent = marker.contentIndent
            var itemLines: [String] = [marker.content]
            i += 1

            while i < lines.count {
                let line = lines[i]
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    let next = (i + 1) < lines.count ? lines[i + 1] : nil
                    let continues = next.map { line2 -> Bool in
                        let lead = line2.prefix(while: { $0 == " " }).count
                        if lead >= contentIndent {
                            return true
                        }
                        return listItemMatch(line2)?.indent == baseIndent
                    } ?? false
                    if continues {
                        loose = true
                        itemLines.append("")
                        i += 1
                        continue
                    }
                    break
                }
                if let sibling = listItemMatch(line), sibling.indent == baseIndent {
                    break
                }
                let lead = line.prefix(while: { $0 == " " }).count
                if lead >= contentIndent {
                    itemLines.append(String(line.dropFirst(contentIndent)))
                    i += 1
                } else if listItemMatch(line)?.indent ?? -1 > baseIndent {
                    itemLines.append(String(line.dropFirst(min(contentIndent, lead))))
                    i += 1
                } else {
                    itemLines.append(line)
                    i += 1
                }
            }
            items.append(parseBlocks(itemLines, references: references, depth: depth + 1))
        }

        return .list(ordered: ordered, start: first.start, tight: !loose, items: items)
    }

    // MARK: Tables (GFM)

    private static func parseTable(_ lines: [String], _ i: inout Int, references: [String: String] = [:]) -> RichTextBlock? {
        guard lines[i].contains("|"), (i + 1) < lines.count, isTableDelimiter(lines[i + 1]) else {
            return nil
        }
        let headers = splitTableRow(lines[i]).map { RichTextInlineParser.parse($0, references: references) }
        let alignments = parseAlignments(lines[i + 1])
        var rows: [[[RichTextInline]]] = []
        var j = i + 2
        while j < lines.count {
            let line = lines[j]
            if line.trimmingCharacters(in: .whitespaces).isEmpty || !line.contains("|") {
                break
            }
            rows.append(splitTableRow(line).map { RichTextInlineParser.parse($0, references: references) })
            j += 1
        }
        i = j
        return .table(headers: headers, alignments: alignments, rows: rows)
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if !t.contains("-") || !t.contains("|") {
            return false
        }
        for c in t where c != "|" && c != ":" && c != "-" && c != " " {
            return false
        }
        return true
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") {
            t = String(t.dropFirst())
        }
        if t.hasSuffix("|") {
            t = String(t.dropLast())
        }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseAlignments(_ line: String) -> [RichTextColumnAlignment] {
        return splitTableRow(line).map { cell in
            let left = cell.hasPrefix(":")
            let right = cell.hasSuffix(":")
            if left && right {
                return .center
            }
            if right {
                return .right
            }
            if left {
                return .left
            }
            return .none
        }
    }

    // MARK: Paragraph

    private static func parseParagraph(_ lines: [String], _ i: inout Int, references: [String: String] = [:]) -> RichTextBlock {
        var collected: [String] = []
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                break
            }
            if isThematicBreak(line) || isFenceStartLine(line) || isBlockQuote(line)
                || parseHeading(line) != nil || listItemMatch(line) != nil {
                break
            }
            if line.contains("|"), (i + 1) < lines.count, isTableDelimiter(lines[i + 1]) {
                break
            }
            collected.append(line)
            i += 1
        }
        return .paragraph(RichTextInlineParser.parse(joinParagraph(collected), references: references))
    }

    private static func joinParagraph(_ lines: [String]) -> String {
        var result = ""
        for (index, raw) in lines.enumerated() {
            let hardBreak = raw.hasSuffix("  ") || raw.hasSuffix("\\")
            var line = String(raw.reversed().drop(while: { $0 == " " }).reversed())
            if hardBreak, line.hasSuffix("\\") {
                line = String(line.dropLast())
            }
            result += line
            if index < lines.count - 1 {
                result += hardBreak ? "\u{2028}" : " "
            }
        }
        return result
    }
}

// MARK: - Inline parser

private struct RichTextInlineParser {
    private let chars: [Character]
    private var pos = 0
    private let references: [String: String]
    // Precomputed last index of ']' / ')' (or -1). Lets a link/image bail out in O(1) when no closing
    // delimiter exists ahead - without it an unbalanced run like "[[[[..." makes every failed parse scan
    // to end-of-input, which combined with the retry-by-one caller is catastrophic (O(2^n) / polynomial).
    private let lastCloseBracket: Int
    private let lastCloseParen: Int
    // Recursion-depth cap for the structural helpers. Real inline nesting never approaches this; past it
    // markup characters are emitted literally so a crafted deep/unbalanced nest cannot blow the stack.
    private static let maxDepth = 32
    // Where an opener of each marker run ("*", "**", "_", "~~"...) first searched to the end of its scope
    // (the text, or the link text it is in) without finding its closer: a later opener of the same run
    // in that scope finds none either, so it stays literal at once. Without it, openers that cannot
    // close each other (a long run of "*" or "_") nest attempts inside attempts and the parse takes
    // exponential time. parseLink gives the link text a scope of its own.
    private var unclosedFrom: [String: Int] = [:]
    // Openers that found their closer: the failed search of an earlier opener ran past them, so they lie
    // after its unclosedFrom entry, yet their own search succeeds ("*a *b* c": *b* still emphasizes).
    private var closedAt: Set<Int> = []
    // The marker run measured last: each position in a long run asks for the same run, and measuring it
    // anew every time made a run of n markers take n * n steps.
    private var lastRun: (start: Int, end: Int) = (0, 0)

    private init(_ text: String, _ references: [String: String]) {
        let characters = Array(text)
        self.chars = characters
        self.references = references
        self.lastCloseBracket = characters.lastIndex(of: "]") ?? -1
        self.lastCloseParen = characters.lastIndex(of: ")") ?? -1
    }

    static func parse(_ text: String, references: [String: String] = [:]) -> [RichTextInline] {
        var parser = RichTextInlineParser(text, references)
        return RichTextAutolinker.link(parser.parseRuns(stop: nil, depth: 0).nodes)
    }

    // `inLink`: the runs are inside link text, where a span opened there must also close there.
    private mutating func parseRuns(stop: String?, depth: Int, inLink: Bool = false) -> (nodes: [RichTextInline], matched: Bool) {
        var nodes: [RichTextInline] = []
        var buffer = ""
        // Past the cap, stop treating markup as structural: emit it literally (advance by one). No text is
        // lost - everything becomes plain text - and recursion is bounded.
        let allowStructural = depth <= Self.maxDepth

        func flush() {
            if !buffer.isEmpty {
                nodes.append(.text(buffer))
                buffer = ""
            }
        }

        while pos < chars.count {
            if let stop, matches(stop, at: pos), isCloser(stop, at: pos) {
                pos += stop.count
                flush()
                return (nodes, true)
            }
            // The ']' ending the link text ends a span opened inside it unclosed, as in CommonMark:
            // "[*a](u) b*" is a link "*a", not emphasis reaching out of the brackets.
            if inLink, chars[pos] == "]" {
                flush()
                return (nodes, false)
            }

            let c = chars[pos]
            switch c {
            case "\\":
                if pos + 1 < chars.count, isEscapable(chars[pos + 1]) {
                    buffer.append(chars[pos + 1])
                    pos += 2
                } else {
                    buffer.append(c)
                    pos += 1
                }
            case "\u{2028}":
                flush()
                nodes.append(.lineBreak)
                pos += 1
            case "`":
                if allowStructural, let node = parseCodeSpan() {
                    flush()
                    nodes.append(node)
                } else {
                    buffer.append(c)
                    pos += 1
                }
            case "*", "_", "~":
                if allowStructural, let node = parseEmphasis(c, depth: depth, inLink: inLink) {
                    flush()
                    nodes.append(node)
                } else {
                    buffer.append(c)
                    pos += 1
                }
            case "!":
                if allowStructural, let node = parseImage() {
                    flush()
                    nodes.append(node)
                } else {
                    buffer.append(c)
                    pos += 1
                }
            case "[":
                if allowStructural, let link = parseLink(depth: depth) {
                    flush()
                    nodes.append(contentsOf: link)
                } else {
                    buffer.append(c)
                    pos += 1
                }
            case "<":
                if allowStructural, let node = parseAngleAutolink() {
                    flush()
                    nodes.append(node)
                } else {
                    buffer.append(c)
                    pos += 1
                }
            case "&":
                if let decoded = parseEntity() {
                    buffer.append(decoded)
                } else {
                    buffer.append(c)
                    pos += 1
                }
            default:
                buffer.append(c)
                pos += 1
            }
        }

        flush()
        return (nodes, false)
    }

    private func matches(_ s: String, at index: Int) -> Bool {
        let needle = Array(s)
        if index + needle.count > chars.count {
            return false
        }
        for k in 0..<needle.count where chars[index + k] != needle[k] {
            return false
        }
        return true
    }

    private func isEscapable(_ c: Character) -> Bool {
        return "\\`*_{}[]()#+-.!~>|\"<&".contains(c)
    }

    // MARK: Flanking (CommonMark 0.29, "left-flanking delimiter run")

    // Whitespace for flanking: the start and end of the text count as whitespace, as do line breaks.
    private static func isFlankingWhitespace(_ c: Character?) -> Bool {
        guard let c else { return true }
        return c.isWhitespace
    }

    // ASCII punctuation, or a Unicode punctuation character.
    private static func isFlankingPunctuation(_ c: Character?) -> Bool {
        guard let c else { return false }
        return "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".contains(c) || c.isPunctuation
    }

    private func character(at index: Int) -> Character? {
        return index >= 0 && index < chars.count ? chars[index] : nil
    }

    // The whole run of `marker` around `index`, so a run is judged as one, as CommonMark does.
    private mutating func run(of marker: Character, around index: Int) -> (start: Int, end: Int) {
        if index >= lastRun.start, index < lastRun.end, chars[index] == marker {
            return lastRun
        }
        var start = index
        while start > 0, chars[start - 1] == marker {
            start -= 1
        }
        var end = index
        while end < chars.count, chars[end] == marker {
            end += 1
        }
        lastRun = (start, end)
        return lastRun
    }

    private func flanking(_ run: (start: Int, end: Int)) -> (left: Bool, right: Bool, before: Character?, after: Character?) {
        let before = character(at: run.start - 1)
        let after = character(at: run.end)
        let left = !Self.isFlankingWhitespace(after)
            && (!Self.isFlankingPunctuation(after) || Self.isFlankingWhitespace(before) || Self.isFlankingPunctuation(before))
        let right = !Self.isFlankingWhitespace(before)
            && (!Self.isFlankingPunctuation(before) || Self.isFlankingWhitespace(after) || Self.isFlankingPunctuation(after))
        return (left, right, before, after)
    }

    // Whether the run of `marker` at `index` can open emphasis: `*` when left-flanking; `_` also not
    // inside a word (snake_case_word).
    private mutating func canOpen(_ marker: Character, at index: Int) -> Bool {
        let f = flanking(run(of: marker, around: index))
        return marker == "_" ? f.left && (!f.right || Self.isFlankingPunctuation(f.before)) : f.left
    }

    // Whether the run of `marker` at `index` can close emphasis: `*` when right-flanking; `_` also not
    // inside a word.
    private mutating func canClose(_ marker: Character, at index: Int) -> Bool {
        let f = flanking(run(of: marker, around: index))
        return marker == "_" ? f.right && (!f.left || Self.isFlankingPunctuation(f.after)) : f.right
    }

    // A stop closes the runs it ends: an emphasis stop only where its run can close.
    private mutating func isCloser(_ stop: String, at index: Int) -> Bool {
        guard let marker = stop.first, marker == "*" || marker == "_" else {
            return true
        }
        return canClose(marker, at: index)
    }

    // MARK: Entities

    // The named entities decoded: the common ones. Others stay literal.
    private static let namedEntities: [String: Character] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}", "hellip": "\u{2026}",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "laquo": "\u{00AB}", "raquo": "\u{00BB}",
        "bull": "\u{2022}", "middot": "\u{00B7}", "deg": "\u{00B0}", "plusmn": "\u{00B1}",
        "times": "\u{00D7}", "divide": "\u{00F7}", "euro": "\u{20AC}", "pound": "\u{00A3}",
        "yen": "\u{00A5}", "cent": "\u{00A2}", "sect": "\u{00A7}", "para": "\u{00B6}",
        "larr": "\u{2190}", "rarr": "\u{2192}", "uarr": "\u{2191}", "darr": "\u{2193}",
        "harr": "\u{2194}", "ne": "\u{2260}", "le": "\u{2264}", "ge": "\u{2265}",
    ]

    // &name; (a common named entity), &#123; or &#x1F600; at pos: its character, pos past it; nil when
    // there is none (the & is literal).
    private mutating func parseEntity() -> Character? {
        var j = pos + 1
        var body = ""
        while j < chars.count, chars[j] != ";", body.count < 32 {
            body.append(chars[j])
            j += 1
        }
        guard j < chars.count, chars[j] == ";", !body.isEmpty else {
            return nil
        }
        var decoded: Character?
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let hex = digits.first == "x" || digits.first == "X"
            let number = hex ? digits.dropFirst() : digits
            let maxDigits = hex ? 6 : 7
            // ASCII digits only: UInt32(_:radix:) would also take a sign ("&#+12;").
            let isDigit: (Character) -> Bool = { $0.isASCII && (hex ? $0.isHexDigit : $0.isNumber) }
            if !number.isEmpty, number.count <= maxDigits, number.allSatisfy(isDigit),
               let value = UInt32(number, radix: hex ? 16 : 10) {
                let scalar = value == 0 ? nil : Unicode.Scalar(value)
                decoded = Character(scalar ?? "\u{FFFD}")
            }
        } else if body.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
            decoded = Self.namedEntities[body]
        }
        guard let decoded else {
            return nil
        }
        pos = j + 1
        return decoded
    }

    // MARK: Autolinks

    // <scheme:...> or <user@host> at pos: a link showing the address (mailto: for an email); nil when
    // the brackets hold neither (HTML, "a < b > c").
    private mutating func parseAngleAutolink() -> RichTextInline? {
        var j = pos + 1
        var content = ""
        while j < chars.count, chars[j] != ">" {
            let c = chars[j]
            if c == "<" || c.isWhitespace {
                return nil
            }
            content.append(c)
            j += 1
        }
        guard j < chars.count, !content.isEmpty else {
            return nil
        }
        let url: String
        if Self.isAutolinkURI(content) {
            url = content
        } else if Self.isAutolinkEmail(content) {
            url = "mailto:" + content
        } else {
            return nil
        }
        pos = j + 1
        return .link(text: [.text(content)], url: url)
    }

    // A scheme of 2 to 32 letters, digits, + . or - (starting with a letter), a colon, and the rest.
    private static func isAutolinkURI(_ s: String) -> Bool {
        guard let colon = s.firstIndex(of: ":") else {
            return false
        }
        let scheme = s[s.startIndex..<colon]
        guard (2...32).contains(scheme.count), let first = scheme.first, first.isASCII, first.isLetter else {
            return false
        }
        return scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "." || $0 == "-") }
    }

    // user@host.domain: the local part of letters, digits and .!#$%&'*+/=?^_`{|}~-, the host of labels
    // of letters, digits and hyphens.
    private static func isAutolinkEmail(_ s: String) -> Bool {
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            return false
        }
        let localAllowed = ".!#$%&'*+/=?^_`{|}~-"
        guard parts[0].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || localAllowed.contains($0)) }) else {
            return false
        }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    // MARK: Link destinations

    // The destination inside (...): <with spaces> (spaces as %20, as Apple's parser gives them), else
    // up to the first whitespace; a title after it ("Title", 'Title', (Title)) is left out.
    private static func linkDestination(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("<"), let close = trimmed.firstIndex(of: ">") {
            let inner = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
            return inner.replacingOccurrences(of: " ", with: "%20")
        }
        return String(trimmed.prefix(while: { !$0.isWhitespace }))
    }

    // ![alt](url) - the alt text is taken literally (image alt is plain text).
    private mutating func parseImage() -> RichTextInline? {
        let start = pos
        guard pos + 1 < chars.count, chars[pos + 1] == "[" else {
            return nil
        }
        pos += 2   // consume '!['
        if pos > lastCloseBracket {   // no ']' ahead: alt text can never close - bail before scanning
            pos = start
            return nil
        }
        var alt = ""
        while pos < chars.count, chars[pos] != "]" {
            alt.append(chars[pos])
            pos += 1
        }
        guard pos < chars.count, chars[pos] == "]", pos + 1 < chars.count, chars[pos + 1] == "(" else {
            pos = start
            return nil
        }
        pos += 2   // consume ']('
        if pos > lastCloseParen {   // no ')' ahead: url can never close - bail before scanning
            pos = start
            return nil
        }
        var url = ""
        var depth = 1
        while pos < chars.count {
            let c = chars[pos]
            if c == "(" {
                depth += 1
                url.append(c)
                pos += 1
            } else if c == ")" {
                depth -= 1
                if depth == 0 {
                    pos += 1
                    return .image(alt: alt, url: Self.linkDestination(url))
                }
                url.append(c)
                pos += 1
            } else {
                url.append(c)
                pos += 1
            }
        }
        pos = start
        return nil
    }

    private mutating func parseCodeSpan() -> RichTextInline? {
        let start = pos
        var ticks = 0
        while pos < chars.count, chars[pos] == "`" {
            ticks += 1
            pos += 1
        }
        var j = pos
        while j < chars.count {
            if chars[j] != "`" {
                j += 1
                continue
            }
            var run = 0
            var k = j
            while k < chars.count, chars[k] == "`" {
                run += 1
                k += 1
            }
            if run == ticks {
                let content = String(chars[pos..<j])
                pos = k
                return .code(trimCodeSpan(content))
            }
            j = k
        }
        pos = start
        return nil
    }

    private func trimCodeSpan(_ s: String) -> String {
        if s.count >= 2, s.first == " ", s.last == " ", s.contains(where: { $0 != " " }) {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    // Whether an opener at `start` that searches for `closer` is already known to find none.
    private func knownUnclosed(_ closer: String, at start: Int) -> Bool {
        return start >= unclosedFrom[closer, default: Int.max] && !closedAt.contains(start)
    }

    // Records the outcome of the search for `closer` from the opener at `start`. A success is kept only
    // where the search parsed structure (below the depth cap), so a cap artifact is not trusted later.
    private mutating func record(_ closer: String, at start: Int, matched: Bool, depth: Int) {
        if matched {
            if depth + 1 <= Self.maxDepth {
                closedAt.insert(start)
            }
        } else {
            closedAt.remove(start)
            unclosedFrom[closer] = min(unclosedFrom[closer, default: Int.max], start)
        }
    }

    private mutating func parseEmphasis(_ marker: Character, depth: Int, inLink: Bool) -> RichTextInline? {
        let start = pos
        let run = run(of: marker, around: start).end - start

        if marker == "~" {
            if run < 2 || knownUnclosed("~~", at: start) {
                pos = start
                return nil
            }
            pos = start + 2
            let inner = parseRuns(stop: "~~", depth: depth + 1, inLink: inLink)
            record("~~", at: start, matched: inner.matched, depth: depth)
            if inner.matched {
                return .strikethrough(inner.nodes)
            }
            pos = start
            return nil
        }

        // A run that cannot open (snake_case_word, 2 * 3 * 4) stays literal.
        if !canOpen(marker, at: start) {
            pos = start
            return nil
        }
        let level = min(run, 3)
        let closer = String(repeating: marker, count: level)
        if knownUnclosed(closer, at: start) {
            pos = start
            return nil
        }
        pos = start + level
        let inner = parseRuns(stop: closer, depth: depth + 1, inLink: inLink)
        record(closer, at: start, matched: inner.matched, depth: depth)
        if inner.matched {
            switch level {
            case 1:
                return .emphasis(inner.nodes)
            case 2:
                return .strong(inner.nodes)
            default:
                return .strong([.emphasis(inner.nodes)])
            }
        }
        pos = start
        return nil
    }

    // [text](url), [text][ref], [text][] or [ref] at pos: the link; or, for an empty destination
    // ([text]()), its text alone, as Apple's parser shows it. nil when it is no link.
    private mutating func parseLink(depth: Int) -> [RichTextInline]? {
        let start = pos
        pos += 1                              // consume '['
        if pos > lastCloseBracket {           // no ']' ahead: not a link in any form - bail in O(1)
            pos = start
            return nil
        }
        let labelStart = pos
        // The link text is a scope of its own for unclosedFrom: a span opened in it ends at its ']'.
        let outerUnclosed = unclosedFrom
        unclosedFrom = [:]
        let text = parseRuns(stop: "]", depth: depth + 1, inLink: true)
        unclosedFrom = outerUnclosed
        guard text.matched else {
            pos = start
            return nil
        }
        let labelString = String(chars[labelStart..<(pos - 1)])   // raw label ('pos' is past the ']')

        // Inline link: [text](url)
        if pos < chars.count, chars[pos] == "(" {
            if pos + 1 > lastCloseParen {     // no ')' ahead: url can never close - bail before scanning
                pos = start
                return nil
            }
            pos += 1
            var url = ""
            var parenDepth = 1
            while pos < chars.count {
                let c = chars[pos]
                if c == "(" {
                    parenDepth += 1
                    url.append(c)
                    pos += 1
                } else if c == ")" {
                    parenDepth -= 1
                    if parenDepth == 0 {
                        pos += 1
                        let destination = Self.linkDestination(url)
                        return destination.isEmpty ? text.nodes : [.link(text: text.nodes, url: destination)]
                    }
                    url.append(c)
                    pos += 1
                } else {
                    url.append(c)
                    pos += 1
                }
            }
            pos = start
            return nil
        }

        // Reference link: [text][ref] or [text][] (collapsed, reuse the text as the label).
        if pos < chars.count, chars[pos] == "[" {
            var j = pos + 1
            while j < chars.count, chars[j] != "]" {
                j += 1
            }
            if j < chars.count {
                let refLabel = String(chars[(pos + 1)..<j]).trimmingCharacters(in: .whitespaces)
                let key = (refLabel.isEmpty ? labelString : refLabel).lowercased()
                if let url = references[key] {
                    pos = j + 1
                    return [.link(text: text.nodes, url: url)]
                }
            }
            pos = start
            return nil
        }

        // Shortcut reference: [ref] - only a link when 'ref' is a defined label (else falls through to
        // literal, so documents without reference definitions are unaffected).
        if let url = references[labelString.lowercased()] {
            return [.link(text: text.nodes, url: url)]
        }

        pos = start
        return nil
    }
}
