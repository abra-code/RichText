// Sources/RichText/Markdown/RichTextMarkdownParser.swift
//
// A small, dependency-free Markdown parser - one convenient way to build a RichTextDocument. It is a
// line-based block parser plus a recursive inline parser covering the subset a chat / document surface
// uses: ATX headings, paragraphs, fenced code, block quotes, ordered / unordered / nested lists,
// thematic breaks, GFM tables; inline **strong**, *emphasis*, ***both***, ~~strike~~, `code`,
// [links](url), escapes, hard breaks.
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

    private mutating func parseRuns(stop: String?, depth: Int) -> (nodes: [RichTextInline], matched: Bool) {
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
            if let stop, matches(stop, at: pos) {
                pos += stop.count
                flush()
                return (nodes, true)
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
                if allowStructural, let node = parseEmphasis(c, depth: depth) {
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
                if allowStructural, let node = parseLink(depth: depth) {
                    flush()
                    nodes.append(node)
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
        return "\\`*_{}[]()#+-.!~>|\"".contains(c)
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
                    return .image(alt: alt, url: url.trimmingCharacters(in: .whitespaces))
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

    private mutating func parseEmphasis(_ marker: Character, depth: Int) -> RichTextInline? {
        let start = pos
        var run = 0
        while pos < chars.count, chars[pos] == marker {
            run += 1
            pos += 1
        }

        if marker == "~" {
            if run < 2 {
                pos = start
                return nil
            }
            pos = start + 2
            let inner = parseRuns(stop: "~~", depth: depth + 1)
            if inner.matched {
                return .strikethrough(inner.nodes)
            }
            pos = start
            return nil
        }

        let level = min(run, 3)
        let closer = String(repeating: marker, count: level)
        pos = start + level
        let inner = parseRuns(stop: closer, depth: depth + 1)
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

    private mutating func parseLink(depth: Int) -> RichTextInline? {
        let start = pos
        pos += 1                              // consume '['
        if pos > lastCloseBracket {           // no ']' ahead: not a link in any form - bail in O(1)
            pos = start
            return nil
        }
        let labelStart = pos
        let text = parseRuns(stop: "]", depth: depth + 1)
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
                        return .link(text: text.nodes, url: url.trimmingCharacters(in: .whitespaces))
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
                    return .link(text: text.nodes, url: url)
                }
            }
            pos = start
            return nil
        }

        // Shortcut reference: [ref] - only a link when 'ref' is a defined label (else falls through to
        // literal, so documents without reference definitions are unaffected).
        if let url = references[labelString.lowercased()] {
            return .link(text: text.nodes, url: url)
        }

        pos = start
        return nil
    }
}
