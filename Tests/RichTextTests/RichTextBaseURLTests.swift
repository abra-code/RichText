// Tests/RichTextTests/RichTextBaseURLTests.swift
//
// RichTextDocument.resolvingImageURLs(against:): relative image paths resolve against the document's own
// location, wherever the image sits in the tree; absolute image URLs and links are left alone.

import XCTest
@testable import RichText

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

final class RichTextBaseURLTests: XCTestCase {
    private let file = URL(string: "file:///Users/me/notes/read.md")!

    private func resolved(_ markdown: String, against base: URL) -> [String] {
        var urls: [String] = []
        func walk(_ inlines: [RichTextInline]) {
            for inline in inlines {
                switch inline {
                case .image(_, let url):
                    urls.append(url)
                case .emphasis(let children), .strong(let children), .strikethrough(let children):
                    walk(children)
                case .link(let text, _):
                    walk(text)
                case .text, .code, .lineBreak:
                    break
                }
            }
        }
        func walk(_ blocks: [RichTextBlock]) {
            for block in blocks {
                switch block {
                case .heading(_, let inlines), .paragraph(let inlines):
                    walk(inlines)
                case .blockQuote(let children):
                    walk(children)
                case .list(_, _, _, let items):
                    items.forEach { walk($0) }
                case .table(let headers, _, let rows):
                    headers.forEach { walk($0) }
                    rows.forEach { $0.forEach { walk($0) } }
                case .codeBlock, .thematicBreak:
                    break
                }
            }
        }
        walk(RichTextDocument(markdown: markdown).resolvingImageURLs(against: base).blocks)
        return urls
    }

    func testRelativePathsResolveAgainstTheDocumentsFile() {
        XCTAssertEqual(resolved("![a](img/a.png)", against: file), ["file:///Users/me/notes/img/a.png"])
        XCTAssertEqual(resolved("![a](../a.png)", against: file), ["file:///Users/me/a.png"])
        XCTAssertEqual(resolved("![a](/srv/a.png)", against: file), ["file:///srv/a.png"])
        XCTAssertEqual(resolved("![a](a.png)", against: file), ["file:///Users/me/notes/a.png"])
    }

    func testAFolderBaseKeepsItsLastComponent() {
        let folder = URL(fileURLWithPath: "/Users/me/notes", isDirectory: true)
        XCTAssertEqual(resolved("![a](img/a.png)", against: folder), ["file:///Users/me/notes/img/a.png"])
    }

    func testAWebPageBaseGivesRemoteImages() {
        let page = URL(string: "https://example.test/docs/guide.md")!
        let urls = resolved("![a](img/a.png)", against: page)
        XCTAssertEqual(urls, ["https://example.test/docs/img/a.png"])
        XCTAssertTrue(RichTextURLPolicy.isRemoteImage(URL(string: urls[0])!), "so RichTextRemoteImages governs it")
    }

    func testAbsoluteURLsAreLeftAlone() {
        let markdown = "![a](https://x.test/a.png) ![b](data:image/png;base64,AAAA) ![c](file:///tmp/c.png)"
        XCTAssertEqual(resolved(markdown, against: file),
                       ["https://x.test/a.png", "data:image/png;base64,AAAA", "file:///tmp/c.png"])
    }

    func testImagesAnywhereInTheTreeResolve() {
        let markdown = """
        # ![h](h.png)

        > - **![q](q.png)** [![l](l.png)](https://x.test)

        | ![t](t.png) |
        | --- |
        | ![r](r.png) |
        """
        XCTAssertEqual(resolved(markdown, against: file), ["h", "q", "l", "t", "r"].map {
            "file:///Users/me/notes/\($0).png"
        })
    }

    // The same strings as the Android port (RichTextBaseUrlTest): what a URL may not hold is percent-encoded,
    // "?" still starts a query, and ".." stops at the root.
    func testEncodingQueriesAndTheRoot() {
        XCTAssertEqual(resolved("![a](<my pic.png?v=1 2#top>)", against: file),
                       ["file:///Users/me/notes/my%20pic.png?v=1%202#top"])
        XCTAssertEqual(resolved("![a](caf\u{e9}.png)", against: file), ["file:///Users/me/notes/caf%C3%A9.png"])
        XCTAssertEqual(resolved("![a](a|b%zz.png)", against: file), ["file:///Users/me/notes/a%7Cb%25zz.png"])
        XCTAssertEqual(resolved("![a](../../../../a.png)", against: file), ["file:///a.png"])
        XCTAssertEqual(resolved("![a](../../a.png)", against: URL(string: "https://example.test/docs/guide.md")!),
                       ["https://example.test/a.png"])
    }

    func testLinksAndEmptyURLsAreLeftAlone() {
        let document = RichTextDocument(blocks: [.paragraph([.link(text: [.text("x")], url: "other.md"),
                                                             .image(alt: "e", url: "")])])
        XCTAssertEqual(document.resolvingImageURLs(against: file), document)
    }
}
