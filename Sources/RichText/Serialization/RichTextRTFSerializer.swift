// Sources/RichText/Serialization/RichTextRTFSerializer.swift
//
// Model -> RTF, including REAL tables (\trowd / \cellx / \intbl / \cell / \row). This is the whole
// point of decoupling serialization from rendering: iOS TextKit has no NSTextTable to serialize, so a
// table copied from the iOS view would otherwise paste as plain text. Writing the RTF ourselves from
// the model lets a copied table paste as a real table into TextEdit / Notes / Word - matching macOS.

import Foundation

public enum RichTextRTFSerializer {

    public static func string(from document: RichTextDocument, images: RichTextImageResolver = { _ in nil }) -> String {
        let header = """
        {\\rtf1\\ansi\\ansicpg1252\\deff0
        {\\fonttbl{\\f0\\fswiss\\fcharset0 Helvetica;}{\\f1\\fmodern\\fcharset0 Courier;}}
        {\\colortbl;\\red0\\green0\\blue0;\\red230\\green230\\blue230;}
        \\fs24
        """
        return header + "\n" + blocks(document.blocks, leftIndent: 0, images: images) + "}\n"
    }

    /// RTF as Data (ASCII; non-ASCII text is escaped as \\uN). `images` resolves an image URL to its loaded
    /// bytes so they can be embedded as a \\pict (unresolved images fall back to the alt text).
    public static func data(from document: RichTextDocument, images: RichTextImageResolver = { _ in nil }) -> Data {
        return Data(string(from: document, images: images).utf8)
    }

    // MARK: - Blocks

    private static func blocks(_ blocks: [RichTextBlock], leftIndent li: Int, images: RichTextImageResolver) -> String {
        return blocks.map { block($0, leftIndent: li, images: images) }.joined()
    }

    private static func block(_ block: RichTextBlock, leftIndent li: Int, images: RichTextImageResolver) -> String {
        switch block {
        case .heading(let level, let inlines):
            let size = headingHalfPoints(level)
            return "\\pard\\sa120\\li\(li)\\b\\fs\(size) " + inline(inlines, images: images) + "\\b0\\fs24\\par\n"
        case .paragraph(let inlines):
            return "\\pard\\sa120\\li\(li) " + inline(inlines, images: images) + "\\par\n"
        case .codeBlock(_, let code):
            let lines = code.components(separatedBy: "\n").map(escape(_:)).joined(separator: "\\line ")
            return "\\pard\\sa120\\li\(li)\\f1\\fs22 " + lines + "\\f0\\fs24\\par\n"
        case .blockQuote(let inner):
            return blocks(inner, leftIndent: li + 360, images: images)
        case .list(let ordered, let start, _, let items):
            return list(ordered: ordered, start: start, items: items, leftIndent: li, images: images)
        case .thematicBreak:
            return "\\pard\\sa120\\li\(li)\\brdrb\\brdrs\\brdrw10\\brsp20 \\par\n\\pard\n"
        case .table(let headers, let alignments, let rows):
            return table(headers: headers, alignments: alignments, rows: rows, leftIndent: li, images: images)
        }
    }

    private static func list(ordered: Bool, start: Int, items: [[RichTextBlock]], leftIndent li: Int,
                             images: RichTextImageResolver) -> String {
        var out = ""
        let itemIndent = li + 360
        for (offset, itemBlocks) in items.enumerated() {
            let marker = ordered ? "\(start + offset)." : "\\u8226 ?"
            var markerUsed = false
            for inner in itemBlocks {
                switch inner {
                case .paragraph(let inlines) where !markerUsed:
                    markerUsed = true
                    out += "\\pard\\fi-360\\li\(itemIndent)\\sa60 " + marker + "\\tab " + inline(inlines, images: images) + "\\par\n"
                case .list(let o, let s, _, let nested):
                    out += list(ordered: o, start: s, items: nested, leftIndent: itemIndent, images: images)
                default:
                    out += block(inner, leftIndent: itemIndent, images: images)
                }
            }
            if !markerUsed {
                out += "\\pard\\fi-360\\li\(itemIndent)\\sa60 " + marker + "\\tab \\par\n"
            }
        }
        return out
    }

    // MARK: - Table (real RTF table)

    private static func table(headers: [[RichTextInline]], alignments: [RichTextColumnAlignment],
                              rows: [[[RichTextInline]]], leftIndent li: Int, images: RichTextImageResolver) -> String {
        let columns = max(headers.count, rows.map(\.count).max() ?? 0)
        if columns == 0 {
            return ""
        }
        let allRows: [([[RichTextInline]], Bool)] = [(headers, true)] + rows.map { ($0, false) }

        // Column widths in twips, from the widest cell text per column (1 char ~ 120 twips).
        var columnChars = [Int](repeating: 0, count: columns)
        for (cells, _) in allRows {
            for column in 0..<columns where column < cells.count {
                columnChars[column] = max(columnChars[column], cells[column].plainText.count)
            }
        }
        var cellx: [Int] = []
        var running = li
        for column in 0..<columns {
            running += max(900, min(4000, columnChars[column] * 120 + 240))
            cellx.append(running)
        }

        let border = "\\clbrdrt\\brdrs\\brdrw10\\clbrdrl\\brdrs\\brdrw10\\clbrdrb\\brdrs\\brdrw10\\clbrdrr\\brdrs\\brdrw10"
        func alignControl(_ column: Int) -> String {
            let a = column < alignments.count ? alignments[column] : .none
            switch a {
            case .center: return "\\qc"
            case .right: return "\\qr"
            default: return "\\ql"
            }
        }

        var out = ""
        for (cells, header) in allRows {
            out += "\\trowd\\trgaph108\\trleft\(li)"
            for column in 0..<columns {
                out += border
                if header {
                    out += "\\clcbpat2"
                }
                out += "\\cellx\(cellx[column])"
            }
            for column in 0..<columns {
                let content = column < cells.count ? inline(cells[column], images: images) : ""
                let bold = header ? "\\b " : ""
                let unbold = header ? "\\b0" : ""
                out += "\\pard\\intbl" + alignControl(column) + " " + bold + content + unbold + "\\cell"
            }
            out += "\\row\n"
        }
        out += "\\pard\\li\(li)\\sa120\n"
        return out
    }

    // MARK: - Inline

    private static func inline(_ nodes: [RichTextInline], images: RichTextImageResolver) -> String {
        var out = ""
        for node in nodes {
            switch node {
            case .text(let s):
                out += escape(s)
            case .emphasis(let c):
                out += "\\i " + inline(c, images: images) + "\\i0 "
            case .strong(let c):
                out += "\\b " + inline(c, images: images) + "\\b0 "
            case .strikethrough(let c):
                out += "\\strike " + inline(c, images: images) + "\\strike0 "
            case .code(let s):
                out += "\\f1 " + escape(s) + "\\f0 "
            case .link(let c, let url):
                out += "{\\field{\\*\\fldinst{HYPERLINK \"" + escape(url) + "\"}}{\\fldrslt " + inline(c, images: images) + "}}"
            case .image(let alt, let url):
                // Embed the bytes as a \pict when we have them AND RTF can carry the format (PNG/JPEG); GIF
                // and anything else fall back to the alt text (the pasteboard's HTML rep still carries them).
                if let loaded = images(url), let picture = pict(loaded) {
                    out += picture
                } else {
                    out += escape(alt.isEmpty ? "[image]" : alt)
                }
            case .lineBreak:
                out += "\\line "
            }
        }
        return out
    }

    // {\pict\pngblip|\jpegblip\picw<px>\pich<px>\picwgoal<tw>\pichgoal<tw> <hex>} - the ORIGINAL bytes as
    // lowercase hex (\jpegblip keeps JPEG photos compact). picw/pich are the native size (points here) and
    // picwgoal/pichgoal the display size in twips (pt * 20); the RTF reader needs picw/pich to size it.
    private static func pict(_ image: RichTextInlineImage) -> String? {
        // Use the format's own bytes if RTF can carry it (PNG/JPEG); otherwise a still PNG frame (e.g. the
        // first frame of a GIF) so a static image still travels; otherwise nothing (fall back to alt text).
        let bytes: Data
        let blip: String
        if let native = image.format.rtfBlip {
            bytes = image.data
            blip = native
        } else if let still = image.stillPNG {
            bytes = still
            blip = "\\pngblip"
        } else {
            return nil
        }
        let pxWidth = max(1, Int(image.displaySize.width.rounded()))
        let pxHeight = max(1, Int(image.displaySize.height.rounded()))
        let goalWidth = Int((image.displaySize.width * 20).rounded())
        let goalHeight = Int((image.displaySize.height * 20).rounded())
        var hex = ""
        hex.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            let s = String(byte, radix: 16)
            hex += byte < 16 ? "0" + s : s
        }
        return "{\\pict\(blip)\\picw\(pxWidth)\\pich\(pxHeight)\\picwgoal\(goalWidth)\\pichgoal\(goalHeight) \(hex)}"
    }

    private static func headingHalfPoints(_ level: Int) -> Int {
        switch level {
        case 1: return 56
        case 2: return 48
        case 3: return 40
        case 4: return 34
        default: return 30
        }
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\":
                out += "\\\\"
            case "{":
                out += "\\{"
            case "}":
                out += "\\}"
            case "\n":
                out += "\\line "
            default:
                if scalar.value < 128 {
                    out.unicodeScalars.append(scalar)
                } else if scalar.value <= 0xFFFF {
                    let signed = scalar.value > 32767 ? Int(scalar.value) - 65536 : Int(scalar.value)
                    out += "\\u\(signed) ?"
                } else {
                    out += "?"
                }
            }
        }
        return out
    }
}
