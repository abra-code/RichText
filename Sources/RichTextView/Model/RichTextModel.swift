// Sources/RichTextView/Model/RichTextModel.swift
//
// The cross-platform document model: a tree of blocks and inline runs. This is the single source of
// truth - it is what the attributed-string builder renders and what the serializers (RTF / HTML /
// Markdown) write. It carries NO platform / TextKit types, so it is testable in isolation and shared
// across iOS / macOS / visionOS.

import Foundation

/// A whole rich-text document: an ordered list of blocks.
public struct RichTextDocument: Equatable, Sendable {
    public var blocks: [RichTextBlock]
    public init(blocks: [RichTextBlock]) {
        self.blocks = blocks
    }
}

/// Per-column alignment for a table.
public enum RichTextColumnAlignment: Equatable, Sendable {
    case none
    case left
    case center
    case right
}

/// A block-level element. Arrival-ordered; lists / quotes nest recursively.
public enum RichTextBlock: Equatable, Sendable {
    case heading(level: Int, [RichTextInline])
    case paragraph([RichTextInline])
    case codeBlock(language: String?, code: String)
    case blockQuote([RichTextBlock])
    case list(ordered: Bool, start: Int, tight: Bool, items: [[RichTextBlock]])
    case thematicBreak
    case table(headers: [[RichTextInline]], alignments: [RichTextColumnAlignment], rows: [[[RichTextInline]]])
}

/// An inline run. Emphasis / strong / strikethrough / link nest; `text` and `code` are leaves.
public enum RichTextInline: Equatable, Sendable {
    case text(String)
    case emphasis([RichTextInline])        // italic
    case strong([RichTextInline])          // bold
    case strikethrough([RichTextInline])
    case code(String)
    case link(text: [RichTextInline], url: String)
    case lineBreak
}

// MARK: - Plain-text extraction (used by serializers + table column measuring)

public extension Array where Element == RichTextInline {
    /// The inline runs flattened to plain text (formatting dropped).
    var plainText: String {
        var out = ""
        for node in self {
            switch node {
            case .text(let s):
                out += s
            case .code(let s):
                out += s
            case .lineBreak:
                out += " "
            case .emphasis(let children), .strong(let children), .strikethrough(let children):
                out += children.plainText
            case .link(let children, _):
                out += children.plainText
            }
        }
        return out
    }
}
