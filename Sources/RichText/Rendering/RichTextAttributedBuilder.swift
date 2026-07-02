// Sources/RichText/Rendering/RichTextAttributedBuilder.swift
//
// Builds ONE NSAttributedString for a whole document so it renders in a single selectable text view.
// Inline styling uses font traits + run attributes; block structure uses paragraph styles plus the
// draw-only MARKER attributes (RichTextAttributes.swift) that the custom layout manager paints
// (code-block rectangle, quote bar, hairline, table grid). Tables are laid out here as tab-stop rows
// with measured, content-sized columns (T1); the grid is drawn by the layout manager.

import Foundation

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public enum RichTextAttributedString {
    /// The whole document as one attributed string. `engine` selects the table strategy: TextKit 1 keeps
    /// the per-platform split (native NSTextTable on macOS), while TextKit 2 always uses the T1 tab-stop
    /// table so the custom layout fragment draws the grid uniformly on both platforms.
    public static func make(_ document: RichTextDocument, theme: RichTextTheme = .default,
                            engine: RichTextEngine = .textKit1) -> NSAttributedString {
        let builder = RichTextAttributedBuilder(theme: theme, engine: engine)
        return builder.build(document.blocks)
    }
}

final class RichTextAttributedBuilder {
    private let storage = NSMutableAttributedString()
    private let theme: RichTextTheme
    private let engine: RichTextEngine

    private let bodyFont: RTVFont
    private let baseSize: CGFloat
    private let monoFont: RTVFont

    init(theme: RichTextTheme, engine: RichTextEngine = .textKit1) {
        self.theme = theme
        self.engine = engine
        self.bodyFont = RTVFonts.body(theme.baseFontSize)
        self.baseSize = bodyFont.pointSize
        // nil baseFontSize => Dynamic Type: the mono font scales with the system text size like the body
        // and headings already do (previously it was a fixed size and stayed small at large text sizes).
        self.monoFont = RTVFonts.monospaced(bodySize: theme.baseFontSize)
    }

    func build(_ blocks: [RichTextBlock]) -> NSAttributedString {
        appendBlocks(blocks, indent: 0, color: RTVColors.label, quoteBarX: nil)
        if storage.string.hasSuffix("\n") {
            storage.deleteCharacters(in: NSRange(location: storage.length - 1, length: 1))
        }
        return storage
    }

    // MARK: - Blocks

    private func appendBlocks(_ blocks: [RichTextBlock], indent: CGFloat, color: RTVColor, quoteBarX: CGFloat?) {
        for block in blocks {
            appendBlock(block, indent: indent, color: color, quoteBarX: quoteBarX)
        }
    }

    private func appendBlock(_ block: RichTextBlock, indent: CGFloat, color: RTVColor, quoteBarX: CGFloat?) {
        switch block {
        case .heading(let level, let inlines):
            let font = RTVFonts.withTraits(RTVFonts.heading(level), bold: true, italic: false)
            let body = renderInlines(inlines, base: font, bold: true, italic: false, strike: false, link: nil, color: color)
            let style = blockStyle(indent: indent)
            style.paragraphSpacingBefore = theme.blockSpacing * 0.6
            style.paragraphSpacing = theme.blockSpacing * 0.5
            emit(body, style: style, quoteBarX: quoteBarX)

        case .paragraph(let inlines):
            let body = renderInlines(inlines, base: bodyFont, bold: false, italic: false, strike: false, link: nil, color: color)
            emit(body, style: blockStyle(indent: indent), quoteBarX: quoteBarX)

        case .codeBlock(let language, let code):
            appendCodeBlock(code, language: language, indent: indent, quoteBarX: quoteBarX)

        case .blockQuote(let inner):
            let barX = indent + theme.indentStep - 12
            appendBlocks(inner, indent: indent + theme.indentStep, color: RTVColors.secondary, quoteBarX: barX)

        case .list(let ordered, let start, _, let items):
            appendList(ordered: ordered, start: start, items: items, indent: indent, color: color, quoteBarX: quoteBarX)

        case .thematicBreak:
            appendThematicBreak(indent: indent, quoteBarX: quoteBarX)

        case .table(let headers, let alignments, let rows):
            appendTable(headers: headers, alignments: alignments, rows: rows, indent: indent, color: color, quoteBarX: quoteBarX)
        }
    }

    private func appendCodeBlock(_ code: String, language: String?, indent: CGFloat, quoteBarX: CGFloat?) {
        // Line breaks become U+2028 so the whole block is ONE paragraph (one layout fragment). That is a
        // 1:1 UTF-16 substitution, so syntax tokens computed from `code` apply at the same offsets.
        let joined = code.components(separatedBy: "\n").joined(separator: "\u{2028}")
        let style = blockStyle(indent: indent)
        style.firstLineHeadIndent = indent + 10
        style.headIndent = indent + 10
        style.tailIndent = -10
        style.paragraphSpacingBefore = 2
        let body = NSMutableAttributedString(string: joined, attributes: [.font: monoFont, .foregroundColor: RTVColors.label])
        if theme.syntaxHighlighting {
            RichTextSyntaxHighlighter.apply(to: body, code: code, language: language)
        }
        emit(body, style: style, quoteBarX: quoteBarX, markers: [.rtvCodeBlock: true])
    }

    private func appendThematicBreak(indent: CGFloat, quoteBarX: CGFloat?) {
        let style = blockStyle(indent: indent)
        style.paragraphSpacingBefore = theme.blockSpacing
        style.minimumLineHeight = 11
        style.maximumLineHeight = 11
        let body = NSAttributedString(string: " ", attributes: [.font: RTVFont.systemFont(ofSize: 1)])
        emit(body, style: style, quoteBarX: quoteBarX, markers: [.rtvRule: true])
    }

    // MARK: - Lists

    private func appendList(ordered: Bool, start: Int, items: [[RichTextBlock]], indent: CGFloat, color: RTVColor, quoteBarX: CGFloat?) {
        for (offset, itemBlocks) in items.enumerated() {
            let marker = ordered ? "\(start + offset)." : "\u{2022}"
            appendListItem(itemBlocks, marker: marker, indent: indent, color: color, quoteBarX: quoteBarX)
        }
    }

    private func appendListItem(_ blocks: [RichTextBlock], marker: String, indent: CGFloat, color: RTVColor, quoteBarX: CGFloat?) {
        var markerUsed = false
        for block in blocks {
            switch block {
            case .paragraph(let inlines) where !markerUsed:
                markerUsed = true
                appendListLine(marker: marker, inlines: inlines, indent: indent, color: color, quoteBarX: quoteBarX)
            case .list(let ordered, let start, _, let nested):
                appendList(ordered: ordered, start: start, items: nested, indent: indent + theme.indentStep, color: color, quoteBarX: quoteBarX)
            default:
                appendBlock(block, indent: indent + theme.indentStep, color: color, quoteBarX: quoteBarX)
            }
        }
        if !markerUsed {
            appendListLine(marker: marker, inlines: [], indent: indent, color: color, quoteBarX: quoteBarX)
        }
    }

    private func appendListLine(marker: String, inlines: [RichTextInline], indent: CGFloat, color: RTVColor, quoteBarX: CGFloat?) {
        let contentIndent = indent + theme.indentStep
        let line = NSMutableAttributedString(string: marker + "\t",
                                             attributes: [.font: bodyFont, .foregroundColor: RTVColors.secondary])
        line.append(renderInlines(inlines, base: bodyFont, bold: false, italic: false, strike: false, link: nil, color: color))
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indent
        style.headIndent = contentIndent
        style.tabStops = [NSTextTab(textAlignment: .left, location: contentIndent)]
        style.paragraphSpacing = theme.listSpacing
        emit(line, style: style, quoteBarX: quoteBarX)
    }

    // MARK: - Tables

    // Table strategy depends on the engine (design doc section 10, "renderer diverges").
    // - TextKit 1: macOS uses a native NSTextTable for wrapping-cell fidelity (P4); iOS / visionOS use the
    //   T1 tab-stop + drawn-grid path (P2, single-line cells), since NSTextTable is AppKit-only.
    // - TextKit 2: BOTH platforms use the T1 tab-stop path, and the custom NSTextLayoutFragment draws the
    //   grid - one rendering path, the substrate for the future wrapping-cell fragment (Strategy T2).
    // Copy is table-aware on both via the RTF serializer regardless of engine.
    private func appendTable(headers: [[RichTextInline]], alignments: [RichTextColumnAlignment],
                             rows: [[[RichTextInline]]], indent: CGFloat, color: RTVColor, quoteBarX: CGFloat?) {
        if engine == .textKit2 {
            appendTableT1(headers: headers, alignments: alignments, rows: rows, indent: indent, color: color, quoteBarX: quoteBarX)
            return
        }
        #if canImport(AppKit)
        appendTableNative(headers: headers, alignments: alignments, rows: rows, color: color)
        #else
        appendTableT1(headers: headers, alignments: alignments, rows: rows, indent: indent, color: color, quoteBarX: quoteBarX)
        #endif
    }

    #if canImport(AppKit)
    // Native bordered NSTextTable (macOS): proportional content-sized columns, WRAPPING cells, real cell
    // borders, per-column alignment, a tinted header row - all selectable as part of the one text view.
    private func appendTableNative(headers: [[RichTextInline]], alignments: [RichTextColumnAlignment],
                                   rows: [[[RichTextInline]]], color: RTVColor) {
        let columns = max(headers.count, rows.map(\.count).max() ?? 0)
        if columns == 0 {
            return
        }
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true

        let bodyRows: [([[RichTextInline]], Bool)] = [(headers, true)] + rows.map { ($0, false) }
        for (rowIndex, entry) in bodyRows.enumerated() {
            let cells = entry.0
            let header = entry.1
            for column in 0..<columns {
                let block = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1,
                                             startingColumn: column, columnSpan: 1)
                block.setBorderColor(RTVColors.separator)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(5, type: .absoluteValueType, for: .padding)
                if header {
                    block.backgroundColor = RTVColors.codeFill
                }
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                let alignment = column < alignments.count ? alignments[column] : .none
                switch alignment {
                case .center: style.alignment = .center
                case .right: style.alignment = .right
                default: style.alignment = .left
                }
                let inlines = column < cells.count ? cells[column] : []
                let content = renderInlines(inlines, base: bodyFont, bold: header, italic: false, strike: false, link: nil, color: color)
                let cell = NSMutableAttributedString(attributedString: content)
                cell.append(NSAttributedString(string: "\n"))
                cell.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: cell.length))
                storage.append(cell)
            }
        }
    }
    #endif

    // T1 (tab-stop rows, measured content-sized columns, grid drawn by the layout manager).
    private func appendTableT1(headers: [[RichTextInline]], alignments: [RichTextColumnAlignment],
                               rows: [[[RichTextInline]]], indent: CGFloat, color: RTVColor, quoteBarX: CGFloat?) {
        let columns = max(headers.count, rows.map(\.count).max() ?? 0)
        if columns == 0 {
            return
        }
        let allRows: [([[RichTextInline]], Bool)] = [(headers, true)] + rows.map { ($0, false) }

        // Render + measure cells.
        let cells: [[NSAttributedString]] = allRows.map { rowPair in
            (0..<columns).map { column in
                let inlines = column < rowPair.0.count ? rowPair.0[column] : []
                return renderInlines(inlines, base: bodyFont, bold: rowPair.1, italic: false, strike: false, link: nil, color: color)
            }
        }
        var columnWidth = [CGFloat](repeating: 0, count: columns)
        for row in cells {
            for (column, cell) in row.enumerated() {
                columnWidth[column] = max(columnWidth[column], ceil(cell.size().width))
            }
        }

        // Cap the LAST column so a long cell wraps within it instead of overflowing on one line; the row
        // grows taller and the wrapped lines indent to the last column (headIndent below). Cells remain
        // real, selectable text (unlike a drawn table).
        let lastColumn = columns - 1
        let maxLastColumnWidth: CGFloat = 320
        columnWidth[lastColumn] = min(columnWidth[lastColumn], maxLastColumnWidth)

        // Column edges (absolute x). edges has columns+1 entries: left of col0 .. right of last col.
        var edges: [CGFloat] = [indent]
        var x = indent
        for column in 0..<columns {
            x += theme.cellPadding * 2 + columnWidth[column]
            edges.append(x)
        }

        func alignment(_ column: Int) -> RichTextColumnAlignment {
            return column < alignments.count ? alignments[column] : .none
        }
        func tab(_ column: Int) -> NSTextTab {
            switch alignment(column) {
            case .right:
                return NSTextTab(textAlignment: .right, location: edges[column + 1] - theme.cellPadding)
            case .center:
                return NSTextTab(textAlignment: .center, location: (edges[column] + edges[column + 1]) / 2)
            default:
                return NSTextTab(textAlignment: .left, location: edges[column] + theme.cellPadding)
            }
        }
        let tabStops = (0..<columns).map(tab)

        for (rowIndex, cellRow) in cells.enumerated() {
            let line = NSMutableAttributedString()
            for column in 0..<columns {
                line.append(NSAttributedString(string: "\t"))
                line.append(cellRow[column])
            }
            line.append(NSAttributedString(string: "\n"))

            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = 0
            style.headIndent = edges[lastColumn] + theme.cellPadding   // wrapped last-cell lines indent to its column
            style.tailIndent = edges[columns]                          // wrap the last cell at the table's right edge
            style.tabStops = tabStops
            style.defaultTabInterval = 0
            style.paragraphSpacing = rowIndex == cells.count - 1 ? theme.blockSpacing : 0

            let info = RichTextTableRowInfo(columnEdges: edges, header: allRows[rowIndex].1,
                                            firstRow: rowIndex == 0, lastRow: rowIndex == cells.count - 1)
            let range = NSRange(location: 0, length: line.length)
            line.addAttribute(.paragraphStyle, value: style, range: range)
            line.addAttribute(.rtvTableRow, value: info, range: range)
            if let quoteBarX {
                line.addAttribute(.rtvQuoteBar, value: quoteBarX, range: range)
            }
            storage.append(line)
        }
    }

    // MARK: - Inline

    private func renderInlines(_ nodes: [RichTextInline], base: RTVFont, bold: Bool, italic: Bool,
                              strike: Bool, link: URL?, color: RTVColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for node in nodes {
            switch node {
            case .text(let s):
                out.append(run(s, font: RTVFonts.withTraits(base, bold: bold, italic: italic), strike: strike, link: link, color: color))
            case .lineBreak:
                out.append(run("\u{2028}", font: base, strike: strike, link: link, color: color))
            case .code(let s):
                out.append(codeRun(s, strike: strike, link: link, color: color))
            case .emphasis(let children):
                out.append(renderInlines(children, base: base, bold: bold, italic: true, strike: strike, link: link, color: color))
            case .strong(let children):
                out.append(renderInlines(children, base: base, bold: true, italic: italic, strike: strike, link: link, color: color))
            case .strikethrough(let children):
                out.append(renderInlines(children, base: base, bold: bold, italic: italic, strike: true, link: link, color: color))
            case .link(let children, let url):
                // Gate the tappable target on the link allow-list: an allow-listed scheme becomes the .link,
                // otherwise fall back to the inherited `link` (nil at top level) so a javascript:/file: target
                // renders as plain, NON-tappable text - the visible link text is kept either way.
                out.append(renderInlines(children, base: base, bold: bold, italic: italic, strike: strike, link: RichTextURLPolicy.allowedLink(url) ?? link, color: color))
            case .image(let alt, let url):
                out.append(NSAttributedString(attachment: RichTextImageAttachment(alt: alt, url: URL(string: url))))
            }
        }
        return out
    }

    private func run(_ s: String, font: RTVFont, strike: Bool, link: URL?, color: RTVColor) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: link == nil ? color : RTVColors.link]
        if strike {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let link {
            attributes[.link] = link
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return NSAttributedString(string: s, attributes: attributes)
    }

    private func codeRun(_ s: String, strike: Bool, link: URL?, color: RTVColor) -> NSAttributedString {
        // The pill is DRAWN by the painter (TK1 layout manager / TK2 fragment) keyed off .rtvInlineCode,
        // instead of a flat .backgroundColor, so inline code gets rounded corners + a little padding.
        var attributes: [NSAttributedString.Key: Any] = [
            .font: monoFont, .foregroundColor: link == nil ? color : RTVColors.link, .rtvInlineCode: true,
        ]
        if strike {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let link {
            attributes[.link] = link
        }
        return NSAttributedString(string: s, attributes: attributes)
    }

    // MARK: - Helpers

    private func emit(_ body: NSAttributedString, style: NSParagraphStyle, quoteBarX: CGFloat?, markers: [NSAttributedString.Key: Any] = [:]) {
        let paragraph = NSMutableAttributedString(attributedString: body)
        paragraph.append(NSAttributedString(string: "\n"))
        let range = NSRange(location: 0, length: paragraph.length)
        paragraph.addAttribute(.paragraphStyle, value: style, range: range)
        for (key, value) in markers {
            paragraph.addAttribute(key, value: value, range: range)
        }
        if let quoteBarX {
            paragraph.addAttribute(.rtvQuoteBar, value: quoteBarX, range: range)
        }
        storage.append(paragraph)
    }

    private func blockStyle(indent: CGFloat) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        style.paragraphSpacing = theme.blockSpacing
        return style
    }
}
