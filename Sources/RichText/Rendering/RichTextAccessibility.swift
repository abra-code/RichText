// Sources/RichText/Rendering/RichTextAccessibility.swift
//
// Builds the VoiceOver representation of a document. The view renders the whole document into ONE selectable
// text view whose decorations (code cards, quote bars, table grid, the tab-stop table layout) are DRAW-ONLY
// and whose images are attachments - none of which a screen reader can recover from the glyph stream. So we
// linearize the MODEL into a speech-friendly string: blocks separated by newlines (VoiceOver pauses there),
// images spoken as their alt text (empty alt = decorative = silent, matching web semantics), and tables read
// row by row with comma-separated cells so columns don't run together. The SwiftUI view exposes this as a
// single static-text accessibility element (see RichText.body).

import Foundation

enum RichTextAccessibility {

    /// A speech-friendly, plain-text linearization of `document` for the view's accessibility label.
    static func label(for document: RichTextDocument) -> String {
        var lines: [String] = []
        append(document.blocks, into: &lines)
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func append(_ blocks: [RichTextBlock], into lines: inout [String]) {
        for block in blocks {
            switch block {
            case .heading(_, let inlines), .paragraph(let inlines):
                lines.append(inlines.plainText)
            case .codeBlock(_, let code):
                lines.append(code.trimmingCharacters(in: .newlines))
            case .blockQuote(let children):
                append(children, into: &lines)
            case .list(_, _, _, let items):
                for item in items {
                    append(item, into: &lines)
                }
            case .thematicBreak:
                break
            case .table(let headers, _, let rows):
                lines.append(rowText(headers))
                for row in rows {
                    lines.append(rowText(row))
                }
            }
        }
    }

    // One table row read as "cell, cell, cell" so VoiceOver announces columns distinctly instead of running
    // the tab-separated cells together.
    private static func rowText(_ cells: [[RichTextInline]]) -> String {
        cells.map { $0.plainText }.joined(separator: ", ")
    }
}
