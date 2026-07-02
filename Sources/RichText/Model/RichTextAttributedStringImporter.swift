// Sources/RichText/Model/RichTextAttributedStringImporter.swift
//
// Reconstructs the RichTextDocument model from a Foundation AttributedString by walking its runs and
// reading block structure back off each run's PresentationIntent - the inverse of what the renderer does.
// This lets a view be created from an AttributedString (typically one from AttributedString(markdown:)
// with .full interpreted syntax) and still recover headings, lists, quotes and GFM tables as real model
// nodes instead of a single flat paragraph.
//
// Key fact: PresentationIntent.components is ordered INNERMOST-to-OUTERMOST - a list item's run reads
// [paragraph, listItem, orderedList]. We reverse it into an outermost-to-innermost "block path" of
// (kind, identity) and fold consecutive runs into a block tree by the shared IntentType.identity at each
// level (runs of the same block share every ancestor identity; the identity changes at the level where a
// new block begins). No @available is needed: PresentationIntent / InlinePresentationIntent are macOS 12 /
// iOS 15, below this package's macOS 13 / iOS 16 / visionOS 1 floor.

import Foundation
import SwiftUI

public extension RichTextDocument {
    /// Reconstruct a document from an AttributedString, recovering block structure from PresentationIntent
    /// and inline styling from InlinePresentationIntent + links. Total by design: unexpected intent shapes
    /// degrade to paragraph text rather than trapping.
    init(attributedString: AttributedString) {
        self.init(blocks: RichTextAttributedStringImporter.blocks(from: attributedString))
    }

    /// Bridge from an NSAttributedString. IMPORTANT: an arbitrary NSAttributedString (e.g. decoded from RTF)
    /// carries NO PresentationIntent, so block structure cannot be recovered and the content collapses to
    /// paragraphs - the reliable source is AttributedString(markdown:options:) with .full interpreted syntax.
    /// We convert including the Foundation scope so any intents that ARE present survive the bridge.
    init(nsAttributedString: NSAttributedString) {
        if let scoped = try? AttributedString(nsAttributedString, including: \.foundation) {
            self.init(attributedString: scoped)
        } else {
            // Conversion can throw for exotic attributes; fall back to plain text, yielding one paragraph.
            self.init(attributedString: AttributedString(nsAttributedString.string))
        }
    }
}

public extension RichText {
    /// Build a view by INTROSPECTING an AttributedString into the model first (recovering headings, lists,
    /// quotes, tables), then rendering that model. Distinct from `init(attributed:)`, which paints a
    /// ready-made NSAttributedString as-is with no structure recovery. Purely additive - the existing
    /// initializers are untouched.
    init(introspecting attributed: AttributedString,
         theme: RichTextTheme = .default,
         engine: RichTextEngine = .textKit1) {
        self.init(RichTextDocument(attributedString: attributed), theme: theme, engine: engine)
    }
}

// MARK: - Importer

enum RichTextAttributedStringImporter {

    // One block level from a run's presentation intent. We keep identity alongside kind because grouping
    // runs into blocks is done by identity (kind alone is ambiguous - two sibling paragraphs share the
    // kind `.paragraph` but differ in identity).
    private struct Component {
        let kind: PresentationIntent.Kind
        let identity: Int
    }

    // A maximal span of runs that share the same block path. Carries the reconstructed inline content and
    // the raw text - the latter is needed for code blocks, whose body is literal text, not inline runs.
    private struct LeafBlock {
        var path: [Component]              // outermost -> innermost
        var inlines: [RichTextInline]
        var text: String
    }

    static func blocks(from attributed: AttributedString) -> [RichTextBlock] {
        buildBlocks(leafBlocks(from: attributed)[...], depth: 0)
    }

    // MARK: Runs -> leaf blocks

    private static func leafBlocks(from attributed: AttributedString) -> [LeafBlock] {
        var leaves: [LeafBlock] = []
        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            let path = blockPath(for: run.presentationIntent)
            let inlines = inlineNodes(text: text,
                                      intent: run.inlinePresentationIntent,
                                      link: run.link)
            // Coalesce into the current leaf when the block path matches (same identities in order). A
            // change of identity starts a new block. An empty path is a plain run -> a paragraph, and
            // consecutive plain runs coalesce into one paragraph.
            if var last = leaves.last, samePath(last.path, path) {
                last.inlines.append(contentsOf: inlines)
                last.text += text
                leaves[leaves.count - 1] = last
            } else {
                leaves.append(LeafBlock(path: path, inlines: inlines, text: text))
            }
        }
        return leaves
    }

    private static func blockPath(for intent: PresentationIntent?) -> [Component] {
        guard let intent else { return [] }
        // components is innermost-first; reverse so index 0 is the top-most container.
        return intent.components.reversed().map { Component(kind: $0.kind, identity: $0.identity) }
    }

    private static func samePath(_ a: [Component], _ b: [Component]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) where x.identity != y.identity { return false }
        return true
    }

    // MARK: Inline mapping

    private static func inlineNodes(text: String,
                                    intent: InlinePresentationIntent?,
                                    link: URL?) -> [RichTextInline] {
        let intent = intent ?? []
        // A hard break (trailing two spaces / backslash in Markdown) becomes a real line break; its own
        // text (a newline) is dropped so it does not double up.
        if intent.contains(.lineBreak) {
            return [.lineBreak]
        }
        // A soft break (a lone newline in the Markdown source) renders as a space in HTML and most
        // renderers; we follow that convention rather than inventing a hard break. Lossy but conventional.
        if intent.contains(.softBreak) {
            return [.text(" ")]
        }
        // A code span is a leaf carrying its text directly; the other spans wrap child inlines. Wrappers are
        // applied innermost-first (strikethrough, then emphasis, then strong, then link outermost) so the
        // nesting is deterministic for equality.
        var node: RichTextInline = intent.contains(.code) ? .code(text) : .text(text)
        if intent.contains(.strikethrough) { node = .strikethrough([node]) }
        if intent.contains(.emphasized) { node = .emphasis([node]) }
        if intent.contains(.stronglyEmphasized) { node = .strong([node]) }
        if let link { node = .link(text: [node], url: link.absoluteString) }
        return [node]
    }

    // MARK: Leaf blocks -> block tree

    private static func buildBlocks(_ leaves: ArraySlice<LeafBlock>, depth: Int) -> [RichTextBlock] {
        var result: [RichTextBlock] = []
        var i = leaves.startIndex
        while i < leaves.endIndex {
            let leaf = leaves[i]
            // Plain run, or a path already consumed at this depth -> a bare paragraph.
            guard depth < leaf.path.count else {
                result.append(.paragraph(leaf.inlines))
                i = leaves.index(after: i)
                continue
            }
            let component = leaf.path[depth]
            // Innermost component: this leaf IS the block (paragraph / heading / code / rule).
            if depth == leaf.path.count - 1 {
                result.append(leafBlock(component, leaf: leaf))
                i = leaves.index(after: i)
                continue
            }
            // A container: gather the run of leaves sharing this container's identity, then recurse into it.
            let identity = component.identity
            var j = leaves.index(after: i)
            while j < leaves.endIndex,
                  depth < leaves[j].path.count,
                  leaves[j].path[depth].identity == identity {
                j = leaves.index(after: j)
            }
            result.append(containerBlock(component, group: leaves[i..<j], depth: depth))
            i = j
        }
        return result
    }

    private static func leafBlock(_ component: Component, leaf: LeafBlock) -> RichTextBlock {
        switch component.kind {
        case .header(let level):
            return .heading(level: level, leaf.inlines)
        case .codeBlock(let languageHint):
            // Body is literal run text; strip trailing newlines cmark appends after the closing fence.
            return .codeBlock(language: languageHint, code: trimmedCode(leaf.text))
        case .thematicBreak:
            return .thematicBreak
        default:
            // .paragraph and any unexpected innermost kind -> keep the text as a paragraph (stay total).
            return .paragraph(leaf.inlines)
        }
    }

    private static func containerBlock(_ component: Component,
                                       group: ArraySlice<LeafBlock>,
                                       depth: Int) -> RichTextBlock {
        switch component.kind {
        case .blockQuote:
            return .blockQuote(buildBlocks(group, depth: depth + 1))
        case .orderedList:
            return listBlock(ordered: true, group: group, depth: depth)
        case .unorderedList:
            return listBlock(ordered: false, group: group, depth: depth)
        case .table:
            return tableBlock(component, group: group)
        default:
            // A container we do not model directly (e.g. a stray listItem/table row) -> flatten its
            // children one level down so nothing is lost.
            let children = buildBlocks(group, depth: depth + 1)
            return children.count == 1 ? children[0] : .blockQuote(children)
        }
    }

    private static func listBlock(ordered: Bool,
                                  group: ArraySlice<LeafBlock>,
                                  depth: Int) -> RichTextBlock {
        var items: [[RichTextBlock]] = []
        var start = 1
        var capturedStart = false
        let itemDepth = depth + 1                        // the listItem level
        var i = group.startIndex
        while i < group.endIndex {
            let leaf = group[i]
            guard itemDepth < leaf.path.count else {
                // Malformed: content directly under the list with no listItem. Treat as a one-block item.
                items.append(buildBlocks(group[i..<group.index(after: i)], depth: itemDepth))
                i = group.index(after: i)
                continue
            }
            let itemComponent = leaf.path[itemDepth]
            // Seed `start` from the first item's ordinal (Markdown lists can begin above 1).
            if ordered, !capturedStart, case .listItem(let ordinal) = itemComponent.kind {
                start = ordinal
                capturedStart = true
            }
            let identity = itemComponent.identity
            var j = group.index(after: i)
            while j < group.endIndex,
                  itemDepth < group[j].path.count,
                  group[j].path[itemDepth].identity == identity {
                j = group.index(after: j)
            }
            // The item's own blocks live one level below the listItem.
            items.append(buildBlocks(group[i..<j], depth: itemDepth + 1))
            i = j
        }
        // `tight` is not expressible in PresentationIntent - default to true (see file notes).
        return .list(ordered: ordered, start: ordered ? start : 1, tight: true, items: items)
    }

    private static func tableBlock(_ tableComponent: Component,
                                   group: ArraySlice<LeafBlock>) -> RichTextBlock {
        var alignments: [RichTextColumnAlignment] = []
        if case .table(let columns) = tableComponent.kind {
            alignments = columns.map { columnAlignment($0.alignment) }
        }
        // Accumulate rows in first-seen order keyed by the row IntentType identity; each row's cells keyed by
        // column index so they order left-to-right and multi-run cells merge.
        struct Row {
            var isHeader: Bool
            var rowIndex: Int
            var cells: [Int: [RichTextInline]]
        }
        var order: [Int] = []
        var rows: [Int: Row] = [:]
        for leaf in group {
            var rowID: Int?
            var isHeader = false
            var rowIndex = 0
            var columnIndex = 0
            // Scan the full path: a cell sits inside a header/body row inside the table.
            for component in leaf.path {
                switch component.kind {
                case .tableHeaderRow:
                    rowID = component.identity; isHeader = true; rowIndex = -1   // header sorts before body
                case .tableRow(let index):
                    rowID = component.identity; isHeader = false; rowIndex = index
                case .tableCell(let index):
                    columnIndex = index
                default:
                    break
                }
            }
            guard let rowID else { continue }            // not actually a table row; skip defensively
            if rows[rowID] == nil {
                rows[rowID] = Row(isHeader: isHeader, rowIndex: rowIndex, cells: [:])
                order.append(rowID)
            }
            if rows[rowID]!.cells[columnIndex] == nil {
                rows[rowID]!.cells[columnIndex] = leaf.inlines
            } else {
                rows[rowID]!.cells[columnIndex]!.append(contentsOf: leaf.inlines)
            }
        }
        var headers: [[RichTextInline]] = []
        var body: [(rowIndex: Int, cells: [[RichTextInline]])] = []
        for id in order {
            let row = rows[id]!
            let cells = row.cells.keys.sorted().map { row.cells[$0]! }
            if row.isHeader {
                headers = cells
            } else {
                body.append((row.rowIndex, cells))
            }
        }
        let sortedRows = body.sorted { $0.rowIndex < $1.rowIndex }.map { $0.cells }
        return .table(headers: headers, alignments: alignments, rows: sortedRows)
    }

    // MARK: Small mappers

    private static func columnAlignment(_ alignment: PresentationIntent.TableColumn.Alignment) -> RichTextColumnAlignment {
        switch alignment {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        // The API has no nil/none case; a GFM column with no colons arrives as .left. The @unknown arm keeps
        // us total against any future case.
        @unknown default: return .none
        }
    }

    private static func trimmedCode(_ text: String) -> String {
        var s = text
        while s.hasSuffix("\n") { s.removeLast() }
        return s
    }
}
