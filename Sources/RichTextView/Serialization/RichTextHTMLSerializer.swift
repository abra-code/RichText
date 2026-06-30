// Sources/RichTextView/Serialization/RichTextHTMLSerializer.swift
//
// Model -> HTML. A real <table> (and the other blocks), for web / rich paste targets.

import Foundation

public enum RichTextHTMLSerializer {

    /// An HTML fragment (no <html>/<body> wrapper).
    public static func fragment(from document: RichTextDocument) -> String {
        return document.blocks.map(block(_:)).joined(separator: "\n")
    }

    /// A full HTML document.
    public static func document(from document: RichTextDocument) -> String {
        return "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"></head><body>\n"
            + fragment(from: document) + "\n</body></html>"
    }

    private static func block(_ block: RichTextBlock) -> String {
        switch block {
        case .heading(let level, let inlines):
            return "<h\(level)>" + inline(inlines) + "</h\(level)>"
        case .paragraph(let inlines):
            return "<p>" + inline(inlines) + "</p>"
        case .codeBlock(let language, let code):
            let cls = language.map { " class=\"language-\($0)\"" } ?? ""
            return "<pre><code\(cls)>" + escape(code) + "</code></pre>"
        case .blockQuote(let inner):
            return "<blockquote>\n" + inner.map(self.block(_:)).joined(separator: "\n") + "\n</blockquote>"
        case .list(let ordered, let start, _, let items):
            let tag = ordered ? "ol" : "ul"
            let startAttr = ordered && start != 1 ? " start=\"\(start)\"" : ""
            let body = items.map { "<li>" + $0.map(self.block(_:)).joined(separator: "\n") + "</li>" }.joined(separator: "\n")
            return "<\(tag)\(startAttr)>\n" + body + "\n</\(tag)>"
        case .thematicBreak:
            return "<hr>"
        case .table(let headers, let alignments, let rows):
            return table(headers: headers, alignments: alignments, rows: rows)
        }
    }

    private static func table(headers: [[RichTextInline]], alignments: [RichTextColumnAlignment],
                              rows: [[[RichTextInline]]]) -> String {
        func style(_ c: Int) -> String {
            let a = c < alignments.count ? alignments[c] : .none
            switch a {
            case .left: return " style=\"text-align:left\""
            case .center: return " style=\"text-align:center\""
            case .right: return " style=\"text-align:right\""
            default: return ""
            }
        }
        var out = "<table>\n<thead>\n<tr>"
        for (c, cell) in headers.enumerated() {
            out += "<th\(style(c))>" + inline(cell) + "</th>"
        }
        out += "</tr>\n</thead>\n<tbody>\n"
        for row in rows {
            out += "<tr>"
            for (c, cell) in row.enumerated() {
                out += "<td\(style(c))>" + inline(cell) + "</td>"
            }
            out += "</tr>\n"
        }
        out += "</tbody>\n</table>"
        return out
    }

    private static func inline(_ nodes: [RichTextInline]) -> String {
        var out = ""
        for node in nodes {
            switch node {
            case .text(let s):
                out += escape(s)
            case .emphasis(let c):
                out += "<em>" + inline(c) + "</em>"
            case .strong(let c):
                out += "<strong>" + inline(c) + "</strong>"
            case .strikethrough(let c):
                out += "<del>" + inline(c) + "</del>"
            case .code(let s):
                out += "<code>" + escape(s) + "</code>"
            case .link(let c, let url):
                out += "<a href=\"" + escapeAttribute(url) + "\">" + inline(c) + "</a>"
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
