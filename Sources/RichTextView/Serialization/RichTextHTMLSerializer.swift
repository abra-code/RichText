// Sources/RichTextView/Serialization/RichTextHTMLSerializer.swift
//
// Model -> HTML. A real <table> (and the other blocks), for web / rich paste targets. Blocks carry
// INLINE styles (style="...", not a <style> block or CSS classes) so the look survives paste into targets
// that strip stylesheets and classes (Notes, TextEdit, Word, Pages): table borders + header shade, the
// code-block / inline-code background, the block-quote bar, heading sizes, and the rule. Colors are fixed
// light-mode hexes - a pasted document is static, so it cannot track the system appearance the way the
// on-screen view does.

import Foundation

public enum RichTextHTMLSerializer {

    /// An HTML fragment (no <html>/<body> wrapper). `images` resolves an image URL to its loaded bytes so
    /// they can be embedded as a data: URI (unresolved images keep the URL).
    public static func fragment(from document: RichTextDocument, images: RichTextImageResolver = { _ in nil }) -> String {
        return document.blocks.map { block($0, images: images) }.joined(separator: "\n")
    }

    /// A full HTML document.
    public static func document(from document: RichTextDocument, images: RichTextImageResolver = { _ in nil }) -> String {
        return "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"></head><body>\n"
            + fragment(from: document, images: images) + "\n</body></html>"
    }

    // MARK: - Style palette (fixed light-mode values; inline so they survive paste)

    private enum CSS {
        static let border = "#c8c8c8"
        static let fill = "#f0f0f0"
        static let secondary = "#6b6b6b"
        static let link = "#0066cc"
        static let mono = "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"

        static let table = "border-collapse:collapse;margin:0.5em 0"
        static let cell = "border:1px solid \(border);padding:5px 7px"
        static let headerCell = "\(cell);background:\(fill)"
        static let codeBlock = "background:\(fill);border-radius:6px;padding:8px 10px;overflow:auto;"
            + "font-family:\(mono);font-size:0.94em;white-space:pre"
        static let inlineCode = "background:\(fill);border-radius:4px;padding:0.1em 0.3em;"
            + "font-family:\(mono);font-size:0.94em"
        static let quote = "border-left:3px solid \(border);margin:0.5em 0;padding:0 0 0 10px;color:\(secondary)"
        static let rule = "border:none;border-top:1px solid \(border);margin:0.6em 0"
        static let anchor = "color:\(link)"

        static func heading(_ level: Int) -> String {
            let size: String
            switch level {
            case 1: size = "1.6em"
            case 2: size = "1.4em"
            case 3: size = "1.2em"
            case 4: size = "1.05em"
            default: size = "1em"
            }
            return "font-weight:600;margin:0.5em 0 0.2em;font-size:\(size)"
        }
    }

    // MARK: - Blocks

    private static func block(_ block: RichTextBlock, images: RichTextImageResolver) -> String {
        switch block {
        case .heading(let level, let inlines):
            return "<h\(level) style=\"\(CSS.heading(level))\">" + inline(inlines, images: images) + "</h\(level)>"
        case .paragraph(let inlines):
            return "<p>" + inline(inlines, images: images) + "</p>"
        case .codeBlock(let language, let code):
            let cls = language.map { " class=\"language-\($0)\"" } ?? ""
            return "<pre style=\"\(CSS.codeBlock)\"><code\(cls)>" + escape(code) + "</code></pre>"
        case .blockQuote(let inner):
            return "<blockquote style=\"\(CSS.quote)\">\n" + inner.map { Self.block($0, images: images) }.joined(separator: "\n") + "\n</blockquote>"
        case .list(let ordered, let start, _, let items):
            let tag = ordered ? "ol" : "ul"
            let startAttr = ordered && start != 1 ? " start=\"\(start)\"" : ""
            let body = items.map { "<li>" + $0.map { Self.block($0, images: images) }.joined(separator: "\n") + "</li>" }.joined(separator: "\n")
            return "<\(tag)\(startAttr)>\n" + body + "\n</\(tag)>"
        case .thematicBreak:
            return "<hr style=\"\(CSS.rule)\">"
        case .table(let headers, let alignments, let rows):
            return table(headers: headers, alignments: alignments, rows: rows, images: images)
        }
    }

    private static func table(headers: [[RichTextInline]], alignments: [RichTextColumnAlignment],
                              rows: [[[RichTextInline]]], images: RichTextImageResolver) -> String {
        func alignmentCSS(_ c: Int) -> String {
            let a = c < alignments.count ? alignments[c] : .none
            switch a {
            case .left: return ";text-align:left"
            case .center: return ";text-align:center"
            case .right: return ";text-align:right"
            default: return ""
            }
        }
        var out = "<table style=\"\(CSS.table)\">\n<thead>\n<tr>"
        for (c, cell) in headers.enumerated() {
            out += "<th style=\"\(CSS.headerCell)\(alignmentCSS(c))\">" + inline(cell, images: images) + "</th>"
        }
        out += "</tr>\n</thead>\n<tbody>\n"
        for row in rows {
            out += "<tr>"
            for (c, cell) in row.enumerated() {
                out += "<td style=\"\(CSS.cell)\(alignmentCSS(c))\">" + inline(cell, images: images) + "</td>"
            }
            out += "</tr>\n"
        }
        out += "</tbody>\n</table>"
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
                out += "<em>" + inline(c, images: images) + "</em>"
            case .strong(let c):
                out += "<strong>" + inline(c, images: images) + "</strong>"
            case .strikethrough(let c):
                out += "<del>" + inline(c, images: images) + "</del>"
            case .code(let s):
                out += "<code style=\"\(CSS.inlineCode)\">" + escape(s) + "</code>"
            case .link(let c, let url):
                out += "<a href=\"" + escapeAttribute(url) + "\" style=\"\(CSS.anchor)\">" + inline(c, images: images) + "</a>"
            case .image(let alt, let url):
                // Embed the bytes as a data: URI when we have them (survives paste); otherwise link the URL.
                let src: String
                if let loaded = images(url) {
                    src = "data:" + loaded.format.mimeType + ";base64," + loaded.data.base64EncodedString()
                } else {
                    src = escapeAttribute(url)
                }
                out += "<img src=\"" + src + "\" alt=\"" + escapeAttribute(alt) + "\" style=\"max-width:100%\">"
            case .lineBreak:
                out += "<br>"
            }
        }
        return out
    }

    private static func escape(_ s: String) -> String {
        return s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ s: String) -> String {
        return escape(s).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
