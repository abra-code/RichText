// Tests/RichTextTests/RichTextURLPolicyTests.swift

import XCTest
@testable import RichText

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

final class RichTextURLPolicyTests: XCTestCase {

    // MARK: - Policy allow-lists

    func testAllowedLinkSchemes() {
        XCTAssertNotNil(RichTextURLPolicy.allowedLink("https://example.com"))
        XCTAssertNotNil(RichTextURLPolicy.allowedLink("http://example.com"))
        XCTAssertNotNil(RichTextURLPolicy.allowedLink("mailto:a@b.com"))
        XCTAssertNotNil(RichTextURLPolicy.allowedLink("tel:+15551234567"))
    }

    func testRejectedLinkSchemes() {
        XCTAssertNil(RichTextURLPolicy.allowedLink("javascript:alert(1)"))
        XCTAssertNil(RichTextURLPolicy.allowedLink("JavaScript:alert(1)"), "scheme match must be case-insensitive")
        XCTAssertNil(RichTextURLPolicy.allowedLink("file:///etc/passwd"))
        XCTAssertNil(RichTextURLPolicy.allowedLink("data:text/html,<b>hi</b>"))
        XCTAssertNil(RichTextURLPolicy.allowedLink("/relative/path"), "a scheme-less/relative link is rejected")
    }

    func testAllowedImageSchemes() {
        XCTAssertTrue(RichTextURLPolicy.allowsImage(URL(string: "https://x.test/y.png")!))
        XCTAssertTrue(RichTextURLPolicy.allowsImage(URL(string: "http://x.test/y.png")!))
        XCTAssertTrue(RichTextURLPolicy.allowsImage(URL(string: "data:image/png;base64,AAAA")!))
    }

    func testRejectedImageSchemes() {
        XCTAssertFalse(RichTextURLPolicy.allowsImage(URL(string: "file:///etc/passwd")!),
                       "a file: image must never be fetched from disk")
        XCTAssertFalse(RichTextURLPolicy.allowsImage(URL(string: "javascript:alert(1)")!))
    }

    // MARK: - Render boundary (attributed string)

    func testJavascriptLinkIsNotTappable() {
        let doc = RichTextDocument(blocks: [.paragraph([.link(text: [.text("tap")], url: "javascript:alert(1)")])])
        let attributed = RichTextAttributedString.make(doc)
        XCTAssertTrue(attributed.string.contains("tap"), "link text must still render")
        var hasLink = false
        attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if value != nil { hasLink = true }
        }
        XCTAssertFalse(hasLink, "javascript: target must not set a tappable .link attribute")
    }

    func testHTTPLinkIsTappable() {
        let doc = RichTextDocument(blocks: [.paragraph([.link(text: [.text("tap")], url: "https://swift.org")])])
        let attributed = RichTextAttributedString.make(doc)
        var linkURL: URL?
        attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if let url = value as? URL { linkURL = url }
        }
        XCTAssertEqual(linkURL, URL(string: "https://swift.org"), "an allow-listed link stays tappable")
    }
}
