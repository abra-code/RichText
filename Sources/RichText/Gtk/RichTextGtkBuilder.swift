// Sources/RichText/Gtk/RichTextGtkBuilder.swift
//
// Fills ONE GtkTextBuffer with a whole document, so it renders in a single selectable GtkTextView: the Linux
// counterpart of RichTextAttributedBuilder. Inline styling and paragraph layout are GtkTextTags (weight,
// style, strikethrough, monospace, margins, paragraph backgrounds, spacing); code blocks are colored from the
// shared syntax tokens; tables are tab-stop rows with measured, content-sized columns, as the TextKit 2 path
// lays them out.
//
// Offsets into the buffer are GTK character offsets, which count Unicode scalars.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import CRichTextGtk

/// The colors a document is drawn with, taken from the GTK style by the view (RichTextGtkView).
struct RichTextGtkPalette {
    var foreground: GdkRGBA
    var secondary: GdkRGBA
    var link: GdkRGBA
    var codeFill: GdkRGBA
    var separator: GdkRGBA
    var syntaxKeyword: GdkRGBA
    var syntaxString: GdkRGBA
    var syntaxNumber: GdkRGBA
    var syntaxComment: GdkRGBA

    /// Adwaita's colors for text in `foreground`: a dark foreground means the light style.
    init(foreground: GdkRGBA) {
        self.foreground = foreground
        let dark = Double(foreground.red) * 0.299 + Double(foreground.green) * 0.587 + Double(foreground.blue) * 0.114 > 0.5
        secondary = GdkRGBA(red: foreground.red, green: foreground.green, blue: foreground.blue, alpha: foreground.alpha * 0.62)
        codeFill = GdkRGBA(red: foreground.red, green: foreground.green, blue: foreground.blue, alpha: 0.07)
        separator = GdkRGBA(red: foreground.red, green: foreground.green, blue: foreground.blue, alpha: 0.18)
        // Adwaita's blue, purple, red and green: the darker shades on light, the lighter ones on dark.
        link = dark ? Self.rgba(0x78AEED) : Self.rgba(0x1C71D8)
        syntaxKeyword = dark ? Self.rgba(0xDC8ADD) : Self.rgba(0x813D9C)
        syntaxString = dark ? Self.rgba(0xF66151) : Self.rgba(0xC01C28)
        syntaxNumber = dark ? Self.rgba(0x99C1F1) : Self.rgba(0x1A5FB4)
        syntaxComment = dark ? Self.rgba(0x8FF0A4) : Self.rgba(0x26A269)
    }

    private static func rgba(_ hex: UInt32) -> GdkRGBA {
        GdkRGBA(red: Float((hex >> 16) & 0xFF) / 255, green: Float((hex >> 8) & 0xFF) / 255,
                blue: Float(hex & 0xFF) / 255, alpha: 1)
    }
}

/// A link's place in the buffer (character offsets) and its allow-listed target.
struct RichTextGtkLink: Equatable {
    let range: Range<Int>
    let url: URL
}

@MainActor
final class RichTextGtkBuilder {
    private let buffer: UnsafeMutablePointer<GtkTextBuffer>
    private let theme: RichTextTheme
    private let palette: RichTextGtkPalette
    private let pango: OpaquePointer   // a PangoContext with the view's font, for measuring table cells
    private var tags: [String: UnsafeMutablePointer<GtkTextTag>] = [:]
    private var offset = 0             // the buffer's length in characters
    private var baseSizeTag: UnsafeMutablePointer<GtkTextTag>?
    private var spacerStart: Int?       // where the latest spacer line starts, and where it ends
    private var spacerEnd: Int?
    private(set) var links: [RichTextGtkLink] = []

    /// The ratio of each heading level's size to the body size: macOS's title1, title2, title3, headline and
    /// subheadline text styles against its 13-point body, which the Apple renderer uses.
    static let headingScale: [Double] = [22.0 / 13, 17.0 / 13, 15.0 / 13, 1, 11.0 / 13]
    static let codeScale = 0.94

    init(buffer: UnsafeMutablePointer<GtkTextBuffer>, theme: RichTextTheme, palette: RichTextGtkPalette,
         pango: OpaquePointer) {
        self.buffer = buffer
        self.theme = theme
        self.palette = palette
        self.pango = pango
    }

    /// Replaces the buffer's text with `document`.
    func build(_ document: RichTextDocument) {
        gtk_text_buffer_set_text(buffer, "", 0)
        offset = 0
        links = []
        spacerStart = nil
        spacerEnd = nil
        // Made before any other tag: a tag table gives later tags the higher priority, so the heading and code
        // tags' own sizes win over the base size. The heading tags come next, before any inline tag, so inline
        // code in a heading takes the code size whatever order the document first uses them in.
        baseSizeTag = theme.baseFontSize.map { namedTag("base-size", [("size-points", .double(Double($0)))]) }
        for level in 1...Self.headingScale.count {
            _ = headingTag(level)
        }
        appendBlocks(document.blocks, indent: 0, secondary: false)
        // No trailing line break after the last block, as on Apple platforms, and no spacer line after a last
        // code block or rule: the text ends with the last block's own text.
        let cut = spacerEnd == offset ? (spacerStart ?? offset) - 1 : offset - 1
        if cut >= 0 {
            var end = GtkTextIter()
            var last = GtkTextIter()
            gtk_text_buffer_get_end_iter(buffer, &end)
            gtk_text_buffer_get_iter_at_offset(buffer, &last, Int32(cut))
            if gtk_text_iter_get_char(&last) == 0x0A {
                gtk_text_buffer_delete(buffer, &last, &end)
                offset = cut
            }
        }
    }

    // MARK: - Blocks

    private func appendBlocks(_ blocks: [RichTextBlock], indent: Double, secondary: Bool) {
        for block in blocks {
            appendBlock(block, indent: indent, secondary: secondary)
        }
    }

    private func appendBlock(_ block: RichTextBlock, indent: Double, secondary: Bool) {
        switch block {
        case .heading(let level, let inlines):
            let start = offset
            appendInlines(inlines, style: InlineStyle(bold: true, secondary: secondary))
            paragraphEnd(start: start, tags: [headingTag(level), marginTag(left: indent)],
                         above: theme.blockSpacing * 0.6, below: theme.blockSpacing * 0.5)

        case .paragraph(let inlines):
            let start = offset
            appendInlines(inlines, style: InlineStyle(secondary: secondary))
            paragraphEnd(start: start, tags: [marginTag(left: indent)], below: theme.blockSpacing)

        case .codeBlock(let language, let code):
            appendCodeBlock(code, language: language, indent: indent)

        case .blockQuote(let inner):
            appendBlocks(inner, indent: indent + Double(theme.indentStep), secondary: true)

        case .list(let ordered, let start, _, let items):
            appendList(ordered: ordered, start: start, items: items, indent: indent, secondary: secondary)

        case .thematicBreak:
            // A line of a tiny font with the separator as its paragraph background: a hairline across the view.
            // The space around it is in lines of their own, since a paragraph background covers its line's
            // spacing. As on Apple platforms (a block's spacing before an 11-point line with the hairline in its
            // middle): the spacing and half the line above, half the line below.
            appendSpacer(Double(theme.blockSpacing) + 5)
            let start = offset
            insert(" ")
            paragraphEnd(start: start, tags: [ruleTag(), marginTag(left: indent)], below: 0)
            appendSpacer(5)

        case .table(let headers, let alignments, let rows):
            appendTable(headers: headers, alignments: alignments, rows: rows, indent: indent, secondary: secondary)
        }
    }

    private func appendCodeBlock(_ code: String, language: String?, indent: Double) {
        let start = offset
        insert(code)
        if theme.syntaxHighlighting {
            let profile = SyntaxProfile.profile(for: language)
            for token in RichTextSyntaxHighlighter.tokenize(code, profile: profile) {
                apply(syntaxTag(token.type), from: start + token.scalarRange.lowerBound, to: start + token.scalarRange.upperBound)
            }
        }
        // The card's background covers its lines' spacing, so the space after the card is a line of its own.
        paragraphEnd(start: start, tags: [codeBlockTag(), marginTag(left: indent + 10, right: 10)], above: 2, below: 2)
        appendSpacer(Double(theme.blockSpacing) - 2)
    }

    // A line of a 1-point font with `height` pixels below it: space after a block whose paragraph background
    // would otherwise cover its own spacing.
    private func appendSpacer(_ height: Double) {
        let start = offset
        insert(" ")
        paragraphEnd(start: start, tags: [namedTag("spacer", [("size-points", .double(1))])], below: RichTextLength(max(0, height)))
        spacerStart = start
        spacerEnd = offset
    }

    // MARK: - Lists

    private func appendList(ordered: Bool, start: Int, items: [[RichTextBlock]], indent: Double, secondary: Bool) {
        for (index, item) in items.enumerated() {
            let marker = ordered ? "\(start + index)." : "\u{2022}"
            appendListItem(item, marker: marker, indent: indent, secondary: secondary)
        }
    }

    private func appendListItem(_ blocks: [RichTextBlock], marker: String, indent: Double, secondary: Bool) {
        var markerUsed = false
        for block in blocks {
            switch block {
            case .paragraph(let inlines) where !markerUsed:
                markerUsed = true
                appendListLine(marker: marker, inlines: inlines, indent: indent, secondary: secondary)
            case .list(let ordered, let start, _, let nested):
                appendList(ordered: ordered, start: start, items: nested, indent: indent + Double(theme.indentStep),
                           secondary: secondary)
            default:
                appendBlock(block, indent: indent + Double(theme.indentStep), secondary: secondary)
            }
        }
        if !markerUsed {
            appendListLine(marker: marker, inlines: [], indent: indent, secondary: secondary)
        }
    }

    // The marker, a tab to the content column, then the item's text; wrapped lines hang at the content column.
    private func appendListLine(marker: String, inlines: [RichTextInline], indent: Double, secondary: Bool) {
        let start = offset
        insert(marker)
        apply(secondaryTag(), from: start, to: offset)
        insert("\t")
        appendInlines(inlines, style: InlineStyle(secondary: secondary))
        paragraphEnd(start: start, tags: [listTag(indent: indent)], below: theme.listSpacing)
    }

    // MARK: - Tables

    // Tab-stop rows with content-sized columns (the TextKit 2 layout on Apple platforms): cells are single
    // lines; the header row is bold on the code fill.
    private func appendTable(headers: [[RichTextInline]], alignments: [RichTextColumnAlignment],
                             rows: [[[RichTextInline]]], indent: Double, secondary: Bool) {
        let columns = max(headers.count, rows.map(\.count).max() ?? 0)
        guard columns > 0 else {
            return
        }
        let allRows: [([[RichTextInline]], Bool)] = [(headers, true)] + rows.map { ($0, false) }
        var widths = [Double](repeating: 0, count: columns)
        for (cells, header) in allRows {
            for column in 0..<min(columns, cells.count) {
                widths[column] = max(widths[column], measure(cells[column], bold: header))
            }
        }
        let padding = Double(theme.cellPadding)
        var edges = [indent]
        for width in widths {
            edges.append(edges[edges.count - 1] + padding * 2 + width)
        }
        let tabs = tableTabs(edges: edges, alignments: alignments, padding: padding)

        for (rowIndex, (cells, header)) in allRows.enumerated() {
            let start = offset
            for column in 0..<columns {
                insert("\t")
                appendInlines(column < cells.count ? cells[column] : [], style: InlineStyle(bold: header, secondary: secondary))
            }
            var rowTags = [tabs]
            if header {
                rowTags.append(headerRowTag())
            }
            paragraphEnd(start: start, tags: rowTags, below: rowIndex == allRows.count - 1 ? theme.blockSpacing : 0)
        }
    }

    // The pixel width of a cell as it is drawn: the body font (bold for a header cell) with the cell's own
    // bold, italic and code runs, so a styled cell does not run past the next column's tab stop (Pango would
    // then move the following cells one stop to the right).
    private func measure(_ inlines: [RichTextInline], bold: Bool) -> Double {
        var text = ""
        let attributes = pango_attr_list_new()!
        defer {
            pango_attr_list_unref(attributes)
        }
        // The list takes ownership of each attribute.
        func add(_ attribute: UnsafeMutablePointer<PangoAttribute>, from start: Int) {
            attribute.pointee.start_index = guint(start)
            attribute.pointee.end_index = guint(text.utf8.count)
            pango_attr_list_insert(attributes, attribute)
        }
        func walk(_ nodes: [RichTextInline]) {
            for node in nodes {
                let start = text.utf8.count
                switch node {
                case .text(let string):
                    text += string
                case .lineBreak:
                    text += "\u{2028}"
                case .code(let string):
                    text += string
                    add(pango_attr_family_new("monospace"), from: start)
                    if let base = theme.baseFontSize {
                        add(pango_attr_size_new(Int32(Double(base) * Self.codeScale * Double(PANGO_SCALE))), from: start)
                    } else {
                        add(pango_attr_scale_new(Self.codeScale), from: start)
                    }
                case .emphasis(let children):
                    walk(children)
                    add(pango_attr_style_new(PANGO_STYLE_ITALIC), from: start)
                case .strong(let children):
                    walk(children)
                    add(pango_attr_weight_new(PANGO_WEIGHT_BOLD), from: start)
                case .strikethrough(let children), .link(let children, _):
                    walk(children)
                case .image(let alt, _):
                    text += alt
                    add(pango_attr_style_new(PANGO_STYLE_ITALIC), from: start)
                }
            }
        }
        walk(inlines)
        let layout = pango_layout_new(pango)!
        defer {
            g_object_unref(UnsafeMutableRawPointer(layout))
        }
        let description = pango_font_description_copy(pango_context_get_font_description(pango))!
        defer {
            pango_font_description_free(description)
        }
        if let size = theme.baseFontSize {
            pango_font_description_set_size(description, Int32(Double(size) * Double(PANGO_SCALE)))
        }
        if bold {
            pango_font_description_set_weight(description, PANGO_WEIGHT_BOLD)
        }
        pango_layout_set_font_description(layout, description)
        pango_layout_set_text(layout, text, -1)
        pango_layout_set_attributes(layout, attributes)
        var width: Int32 = 0
        var height: Int32 = 0
        pango_layout_get_pixel_size(layout, &width, &height)
        return Double(width)
    }

    // A tag with the row's tab stops: one per column, at the cell's start, middle or end by its alignment.
    private func tableTabs(edges: [Double], alignments: [RichTextColumnAlignment], padding: Double)
        -> UnsafeMutablePointer<GtkTextTag> {
        let columns = edges.count - 1
        let array = pango_tab_array_new(Int32(columns), 1)!
        defer {
            pango_tab_array_free(array)
        }
        for column in 0..<columns {
            let alignment = column < alignments.count ? alignments[column] : .none
            switch alignment {
            case .right:
                pango_tab_array_set_tab(array, Int32(column), PANGO_TAB_RIGHT, Int32(edges[column + 1] - padding))
            case .center:
                pango_tab_array_set_tab(array, Int32(column), PANGO_TAB_CENTER, Int32((edges[column] + edges[column + 1]) / 2))
            default:
                pango_tab_array_set_tab(array, Int32(column), PANGO_TAB_LEFT, Int32(edges[column] + padding))
            }
        }
        let tag = newTag([])
        Self.set(tag, "tabs", .boxed(pango_tab_array_get_type(), UnsafeMutableRawPointer(array)))
        return tag
    }

    // MARK: - Inline

    private struct InlineStyle {
        var bold = false
        var italic = false
        var strike = false
        var secondary = false
        var link: URL?
    }

    private func appendInlines(_ nodes: [RichTextInline], style: InlineStyle) {
        for node in nodes {
            switch node {
            case .text(let text):
                run(text, style: style, code: false)
            case .lineBreak:
                run("\u{2028}", style: style, code: false)
            case .code(let text):
                run(text, style: style, code: true)
            case .emphasis(let children):
                var inner = style
                inner.italic = true
                appendInlines(children, style: inner)
            case .strong(let children):
                var inner = style
                inner.bold = true
                appendInlines(children, style: inner)
            case .strikethrough(let children):
                var inner = style
                inner.strike = true
                appendInlines(children, style: inner)
            case .link(let children, let url):
                // Only an allow-listed target becomes a link; otherwise the text stays plain (as on Apple).
                var inner = style
                inner.link = RichTextURLPolicy.allowedLink(url) ?? style.link
                appendInlines(children, style: inner)
            case .image(let alt, _):
                // Images come with their loader; until then the alt text stands in, dimmed.
                var inner = style
                inner.secondary = true
                inner.italic = true
                run(alt, style: inner, code: false)
            }
        }
    }

    private func run(_ text: String, style: InlineStyle, code: Bool) {
        guard !text.isEmpty else {
            return
        }
        let start = offset
        insert(text)
        var runTags: [UnsafeMutablePointer<GtkTextTag>] = []
        if style.bold {
            runTags.append(namedTag("bold", [("weight", .int(Int32(PANGO_WEIGHT_BOLD.rawValue)))]))
        }
        if style.italic {
            runTags.append(namedTag("italic", [("style", .enumeration(pango_style_get_type(), Int32(PANGO_STYLE_ITALIC.rawValue)))]))
        }
        if style.strike {
            runTags.append(namedTag("strike", [("strikethrough", .boolean(true))]))
        }
        if code {
            runTags.append(codeTag())
        }
        if let link = style.link {
            runTags.append(namedTag("link", [("foreground-rgba", .rgba(palette.link)),
                                             ("underline", .enumeration(pango_underline_get_type(),
                                                                        Int32(PANGO_UNDERLINE_SINGLE.rawValue)))]))
            links.append(RichTextGtkLink(range: start..<offset, url: link))
        } else if style.secondary {
            runTags.append(secondaryTag())
        }
        for tag in runTags {
            apply(tag, from: start, to: offset)
        }
    }

    // MARK: - Tags

    private func headingTag(_ level: Int) -> UnsafeMutablePointer<GtkTextTag> {
        let index = min(max(level, 1), 5) - 1
        let scale = Self.headingScale[index]
        return namedTag("h\(index + 1)", [("weight", .int(Int32(PANGO_WEIGHT_BOLD.rawValue))), sizeProperty(scale)])
    }

    private func codeTag() -> UnsafeMutablePointer<GtkTextTag> {
        namedTag("code", [("family", .string("monospace")), sizeProperty(Self.codeScale),
                          ("background-rgba", .rgba(palette.codeFill))])
    }

    private func codeBlockTag() -> UnsafeMutablePointer<GtkTextTag> {
        namedTag("code-block", [("family", .string("monospace")), sizeProperty(Self.codeScale),
                                ("paragraph-background-rgba", .rgba(palette.codeFill))])
    }

    private func ruleTag() -> UnsafeMutablePointer<GtkTextTag> {
        namedTag("rule", [("size-points", .double(1)), ("paragraph-background-rgba", .rgba(palette.separator))])
    }

    private func headerRowTag() -> UnsafeMutablePointer<GtkTextTag> {
        namedTag("header-row", [("paragraph-background-rgba", .rgba(palette.codeFill))])
    }

    private func secondaryTag() -> UnsafeMutablePointer<GtkTextTag> {
        namedTag("secondary", [("foreground-rgba", .rgba(palette.secondary))])
    }

    private func syntaxTag(_ type: RichTextSyntaxHighlighter.TokenType) -> UnsafeMutablePointer<GtkTextTag> {
        switch type {
        case .keyword: return namedTag("syntax-keyword", [("foreground-rgba", .rgba(palette.syntaxKeyword))])
        case .string: return namedTag("syntax-string", [("foreground-rgba", .rgba(palette.syntaxString))])
        case .number: return namedTag("syntax-number", [("foreground-rgba", .rgba(palette.syntaxNumber))])
        case .comment: return namedTag("syntax-comment", [("foreground-rgba", .rgba(palette.syntaxComment))])
        }
    }

    private func marginTag(left: Double, right: Double = 0) -> UnsafeMutablePointer<GtkTextTag> {
        let l = Int32(left.rounded())
        let r = Int32(right.rounded())
        return namedTag("margin-\(l)-\(r)", [("left-margin", .int(l)), ("right-margin", .int(r))])
    }

    // A list line: it starts at `indent`, its marker's tab reaches the content column one indent step in, and
    // its wrapped lines hang at that column.
    private func listTag(indent: Double) -> UnsafeMutablePointer<GtkTextTag> {
        let step = Int32(Double(theme.indentStep).rounded())
        let left = Int32(indent.rounded())
        let key = "list-\(left)-\(step)"
        if let existing = tags[key] {
            return existing
        }
        let array = pango_tab_array_new(1, 1)!
        defer {
            pango_tab_array_free(array)
        }
        pango_tab_array_set_tab(array, 0, PANGO_TAB_LEFT, step)
        let tag = namedTag(key, [("left-margin", .int(left)), ("indent", .int(-step))])
        Self.set(tag, "tabs", .boxed(pango_tab_array_get_type(), UnsafeMutableRawPointer(array)))
        return tag
    }

    // The size of a heading or code run: a scale of the view's font, or of the theme's base size when set (a
    // point size replaces a lower-priority tag's size, while GTK multiplies the scales of all tags on a run).
    private func sizeProperty(_ scale: Double) -> (String, TagValue) {
        if let base = theme.baseFontSize {
            return ("size-points", .double(Double(base) * scale))
        }
        return ("scale", .double(scale))
    }

    // MARK: - Buffer

    // Ends the paragraph that started at `start`: a line break, then the block's tags over the whole paragraph,
    // the base size when the theme sets one, and the spacing.
    private func paragraphEnd(start: Int, tags blockTags: [UnsafeMutablePointer<GtkTextTag>],
                              above: RichTextLength = 0, below: RichTextLength) {
        insert("\n")
        for tag in blockTags {
            apply(tag, from: start, to: offset)
        }
        if let baseSizeTag {
            apply(baseSizeTag, from: start, to: offset)
        }
        // Spacing goes around the block, not between its lines (a code block is one paragraph per line): above
        // on the first line, below on the last.
        let a = Int32(Double(above).rounded())
        let b = Int32(Double(below).rounded())
        if a > 0 {
            // Through the line break, so an empty first line (its paragraph properties are read there) has it too.
            apply(namedTag("above-\(a)", [("pixels-above-lines", .int(a))]), from: start, to: lineEnd(from: start) + 1)
        }
        if b > 0 {
            apply(namedTag("below-\(b)", [("pixels-below-lines", .int(b))]), from: lineStart(before: offset), to: offset)
        }
    }

    // The offset where the line holding `offset` ends (before its line break).
    private func lineEnd(from offset: Int) -> Int {
        var iter = GtkTextIter()
        gtk_text_buffer_get_iter_at_offset(buffer, &iter, Int32(offset))
        if gtk_text_iter_ends_line(&iter) == 0 {
            gtk_text_iter_forward_to_line_end(&iter)
        }
        return Int(gtk_text_iter_get_offset(&iter))
    }

    // The offset where the line ending just before `offset` starts.
    private func lineStart(before offset: Int) -> Int {
        var iter = GtkTextIter()
        gtk_text_buffer_get_iter_at_offset(buffer, &iter, Int32(max(0, offset - 1)))
        gtk_text_iter_set_line_offset(&iter, 0)
        return Int(gtk_text_iter_get_offset(&iter))
    }

    private func insert(_ text: String) {
        // A NUL would end the C string early and shift every later offset; U+FFFD replaces it one for one, as
        // CommonMark asks.
        let text = text.unicodeScalars.contains("\u{0}")
            ? String(String.UnicodeScalarView(text.unicodeScalars.map { $0 == "\u{0}" ? "\u{FFFD}" : $0 })) : text
        var end = GtkTextIter()
        gtk_text_buffer_get_end_iter(buffer, &end)
        gtk_text_buffer_insert(buffer, &end, text, -1)
        offset += text.unicodeScalars.count
    }

    private func apply(_ tag: UnsafeMutablePointer<GtkTextTag>, from start: Int, to end: Int) {
        var from = GtkTextIter()
        var to = GtkTextIter()
        gtk_text_buffer_get_iter_at_offset(buffer, &from, Int32(start))
        gtk_text_buffer_get_iter_at_offset(buffer, &to, Int32(end))
        gtk_text_buffer_apply_tag(buffer, tag, &from, &to)
    }

    // A tag kept by name for this buffer, made on first use with `properties`.
    private func namedTag(_ name: String, _ properties: [(String, TagValue)]) -> UnsafeMutablePointer<GtkTextTag> {
        if let existing = tags[name] {
            return existing
        }
        let tag = newTag(properties)
        tags[name] = tag
        return tag
    }

    // A new anonymous tag in the buffer's tag table, which keeps it.
    private func newTag(_ properties: [(String, TagValue)]) -> UnsafeMutablePointer<GtkTextTag> {
        let tag = gtk_text_tag_new(nil)!
        for (name, value) in properties {
            Self.set(tag, name, value)
        }
        gtk_text_tag_table_add(gtk_text_buffer_get_tag_table(buffer), tag)
        g_object_unref(UnsafeMutableRawPointer(tag))
        return tag
    }

    enum TagValue {
        case int(Int32)
        case double(Double)
        case boolean(Bool)
        case string(String)
        case enumeration(GType, Int32)
        case rgba(GdkRGBA)
        case boxed(GType, UnsafeMutableRawPointer)
    }

    // GObject's fundamental types are macros Swift does not import: G_TYPE_MAKE_FUNDAMENTAL(n) is n << 2.
    private static func fundamental(_ number: Int) -> GType {
        GType(number << Int(G_TYPE_FUNDAMENTAL_SHIFT))
    }

    static func set(_ tag: UnsafeMutablePointer<GtkTextTag>, _ name: String, _ value: TagValue) {
        var gvalue = GValue()
        switch value {
        case .int(let number):
            g_value_init(&gvalue, fundamental(6))   // G_TYPE_INT
            g_value_set_int(&gvalue, number)
        case .double(let number):
            g_value_init(&gvalue, fundamental(15))  // G_TYPE_DOUBLE
            g_value_set_double(&gvalue, number)
        case .boolean(let flag):
            g_value_init(&gvalue, fundamental(5))   // G_TYPE_BOOLEAN
            g_value_set_boolean(&gvalue, flag ? 1 : 0)
        case .string(let text):
            g_value_init(&gvalue, fundamental(16))  // G_TYPE_STRING
            g_value_set_string(&gvalue, text)
        case .enumeration(let type, let number):
            g_value_init(&gvalue, type)
            g_value_set_enum(&gvalue, number)
        case .rgba(var color):
            g_value_init(&gvalue, gdk_rgba_get_type())
            g_value_set_boxed(&gvalue, &color)
        case .boxed(let type, let pointer):
            g_value_init(&gvalue, type)
            g_value_set_boxed(&gvalue, pointer)   // copies the boxed value
        }
        g_object_set_property(UnsafeMutableRawPointer(tag).assumingMemoryBound(to: GObject.self), name, &gvalue)
        g_value_unset(&gvalue)
    }
}
