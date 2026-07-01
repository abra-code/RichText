// Sources/RichTextView/Serialization/RichTextMarkdownSerializer.swift
//
// Model -> Markdown. The inverse of the parser; used for plain round-trip on the pasteboard.

import Foundation

public enum RichTextMarkdownSerializer {

    public static func string(from document: RichTextDocument) -> String {
        return blocks(document.blocks, indent: "")
    }

    private static func blocks(_ blocks: [RichTextBlock], indent: String) -> String {
        return blocks.map { block(_:$0, indent: indent) }.joined(separator: "\n\n")
    }

    private static func block(_ block: RichTextBlock, indent: String) -> String {
        switch block {
        case .heading(let level, let inlines):
            return String(repeating: "#", count: level) + " " + inline(inlines)
        case .paragraph(let inlines):
            return inline(inlines)
        case .codeBlock(let language, let code):
            return "```" + (language ?? "") + "\n" + code + "\n```"
        case .blockQuote(let inner):
            return blocks(inner, indent: "").split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> " + $0 }.joined(separator: "\n")
        case .list(let ordered, let start, _, let items):
            return list(ordered: ordered, start: start, items: items, indent: indent)
        case .thematicBreak:
            return "---"
        case .table(let headers, let alignments, let rows):
            return table(headers: headers, alignments: alignments, rows: rows)
        }
    }

    private static func list(ordered: Bool, start: Int, items: [[RichTextBlock]], indent: String) -> String {
        var lines: [String] = []
        for (offset, itemBlocks) in items.enumerated() {
            let marker = ordered ? "\(start + offset). " : "- "
            let rendered = blocks(itemBlocks, indent: indent + "  ")
            let parts = rendered.split(separator: "\n", omittingEmptySubsequences: false)
            for (lineIndex, part) in parts.enumerated() {
                if lineIndex == 0 {
                    lines.append(indent + marker + part)
                } else {
                    lines.append(indent + "  " + part)
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func table(headers: [[RichTextInline]], alignments: [RichTextColumnAlignment],
                              rows: [[[RichTextInline]]]) -> String {
        let columns = max(headers.count, rows.map(\.count).max() ?? 0)
        func cell(_ cells: [[RichTextInline]], _ c: Int) -> String {
            return c < cells.count ? inline(cells[c]) : ""
        }
        func delimiter(_ c: Int) -> String {
            let a = c < alignments.count ? alignments[c] : .none
            switch a {
            case .left: return ":---"
            case .center: return ":---:"
            case .right: return "---:"
            default: return "---"
            }
        }
        var lines: [String] = []
        lines.append("| " + (0..<columns).map { cell(headers, $0) }.joined(separator: " | ") + " |")
        lines.append("| " + (0..<columns).map(delimiter).joined(separator: " | ") + " |")
        for row in rows {
            lines.append("| " + (0..<columns).map { cell(row, $0) }.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    static func inline(_ nodes: [RichTextInline]) -> String {
        var out = ""
        for node in nodes {
            switch node {
            case .text(let s):
                out += s
            case .emphasis(let c):
                out += "*" + inline(c) + "*"
            case .strong(let c):
                out += "**" + inline(c) + "**"
            case .strikethrough(let c):
                out += "~~" + inline(c) + "~~"
            case .code(let s):
                out += "`" + s + "`"
            case .link(let c, let url):
                out += "[" + inline(c) + "](" + url + ")"
            case .image(let alt, let url):
                out += "![" + alt + "](" + url + ")"
            case .lineBreak:
                out += "  \n"
            }
        }
        return out
    }
}
