// Sources/RichText/Model/RichTextDocument+BaseURL.swift
//
// Relative image paths resolved against the document's own location: `![](img/a.png)` in a Markdown file
// on disk names a picture beside that file. A string of Markdown has no location, so the caller supplies it.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public extension RichTextDocument {
    /// A copy whose relative image URLs (those without a scheme, such as `img/a.png`, `../b.jpg` or
    /// `/c.png`) are resolved against `base`, the document's own URL: a file's URL (`file:///docs/read.md`),
    /// a folder's URL ending in "/" (`URL(fileURLWithPath: folder, isDirectory: true)`), or a web page's URL.
    /// Resolved against a web page, the images are remote and follow `RichTextRemoteImages`. Absolute URLs,
    /// links and everything else are left as they are, and a path that cannot be resolved stays relative
    /// (its image is unavailable).
    func resolvingImageURLs(against base: URL) -> RichTextDocument {
        RichTextDocument(blocks: blocks.map { $0.resolvingImageURLs(against: base) })
    }
}

extension RichTextBlock {
    func resolvingImageURLs(against base: URL) -> RichTextBlock {
        switch self {
        case .heading(let level, let inlines):
            return .heading(level: level, inlines.resolvingImageURLs(against: base))
        case .paragraph(let inlines):
            return .paragraph(inlines.resolvingImageURLs(against: base))
        case .blockQuote(let blocks):
            return .blockQuote(blocks.map { $0.resolvingImageURLs(against: base) })
        case .list(let ordered, let start, let tight, let items):
            return .list(ordered: ordered, start: start, tight: tight,
                         items: items.map { $0.map { $0.resolvingImageURLs(against: base) } })
        case .table(let headers, let alignments, let rows):
            return .table(headers: headers.map { $0.resolvingImageURLs(against: base) }, alignments: alignments,
                          rows: rows.map { $0.map { $0.resolvingImageURLs(against: base) } })
        case .codeBlock, .thematicBreak:
            return self
        }
    }
}

extension Array where Element == RichTextInline {
    func resolvingImageURLs(against base: URL) -> [RichTextInline] {
        map { $0.resolvingImageURLs(against: base) }
    }
}

extension RichTextInline {
    func resolvingImageURLs(against base: URL) -> RichTextInline {
        switch self {
        case .image(let alt, let url):
            return .image(alt: alt, url: RichTextInline.resolvedImageURL(url, against: base))
        case .emphasis(let children):
            return .emphasis(children.resolvingImageURLs(against: base))
        case .strong(let children):
            return .strong(children.resolvingImageURLs(against: base))
        case .strikethrough(let children):
            return .strikethrough(children.resolvingImageURLs(against: base))
        case .link(let text, let url):
            return .link(text: text.resolvingImageURLs(against: base), url: url)
        case .text, .code, .lineBreak:
            return self
        }
    }

    // `url` resolved against `base` when it has no scheme; otherwise, or when it does not parse, unchanged.
    static func resolvedImageURL(_ url: String, against base: URL) -> String {
        guard !url.isEmpty, let parsed = URL(string: url, relativeTo: base), URL(string: url)?.scheme == nil else {
            return url
        }
        return parsed.absoluteString
    }
}
