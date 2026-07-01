// Sources/RichText/Markdown/RichTextAutolinker.swift
//
// A post-pass over inline nodes that turns bare URLs in plain text into links (GFM-style autolinking), so
// a URL typed without [](...) is still tappable. It runs after inline parsing, walking only `.text` nodes
// and recursing into emphasis / strong / strikethrough - it deliberately does NOT touch `.code` or an
// existing `.link` (so a URL inside inline code, or the visible text of a real link, is left alone).
//
// URL detection uses NSDataDetector, so boundary rules (trailing sentence punctuation, "www." prefixes
// getting an http scheme, etc.) match the system's link detection rather than a hand-rolled regex.

import Foundation

enum RichTextAutolinker {
    static func link(_ nodes: [RichTextInline]) -> [RichTextInline] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nodes
        }
        return apply(nodes, detector)
    }

    private static func apply(_ nodes: [RichTextInline], _ detector: NSDataDetector) -> [RichTextInline] {
        return nodes.flatMap { node -> [RichTextInline] in
            switch node {
            case .text(let string):
                return split(string, detector)
            case .emphasis(let children):
                return [.emphasis(apply(children, detector))]
            case .strong(let children):
                return [.strong(apply(children, detector))]
            case .strikethrough(let children):
                return [.strikethrough(apply(children, detector))]
            case .code, .link, .image, .lineBreak:
                return [node]
            }
        }
    }

    private static func split(_ text: String, _ detector: NSDataDetector) -> [RichTextInline] {
        guard !text.isEmpty else {
            return [.text(text)]
        }
        let string = text as NSString
        let matches = detector.matches(in: text, options: [], range: NSRange(location: 0, length: string.length))
        guard !matches.isEmpty else {
            return [.text(text)]
        }

        var result: [RichTextInline] = []
        var cursor = 0
        for match in matches {
            guard let url = match.url else {
                continue
            }
            if match.range.location > cursor {
                let plain = string.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                result.append(.text(plain))
            }
            let display = string.substring(with: match.range)
            result.append(.link(text: [.text(display)], url: url.absoluteString))
            cursor = match.range.location + match.range.length
        }
        if cursor < string.length {
            result.append(.text(string.substring(from: cursor)))
        }
        return result
    }
}
