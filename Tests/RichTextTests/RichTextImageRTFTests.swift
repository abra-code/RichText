// Tests/RichTextTests/RichTextImageRTFTests.swift
//
// Image copy fidelity for RTF: a loaded image embeds as a {\pict\pngblip ...} so the picture survives
// paste into TextEdit / Word; an unloaded image falls back to the alt text.

import XCTest
@testable import RichText

final class RichTextImageRTFTests: XCTestCase {

    private let imageDoc = RichTextDocument(markdown: "![cat](https://x.test/cat.png)")

    // A minimal valid 1x1 PNG.
    private let tinyPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    func testRTFEmbedsImageAsPict() {
        let png = tinyPNG
        let resolver: RichTextImageResolver = { _ in RichTextInlineImage(data: png, format: .png, displaySize: CGSize(width: 10, height: 10)) }
        let rtf = RichTextRTFSerializer.string(from: imageDoc, images: resolver)
        XCTAssertTrue(rtf.contains("\\pict\\pngblip"), "expected a \\pict")
        XCTAssertTrue(rtf.contains("89504e47"), "expected the PNG signature bytes in hex")   // 89 50 4E 47
    }

    func testRTFEmbedsJPEGAsJpegblip() {
        // A JPEG stays a JPEG (\jpegblip) - not re-encoded to a huge PNG.
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let resolver: RichTextImageResolver = { _ in RichTextInlineImage(data: jpeg, format: .jpeg, displaySize: CGSize(width: 10, height: 10)) }
        let rtf = RichTextRTFSerializer.string(from: imageDoc, images: resolver)
        XCTAssertTrue(rtf.contains("\\pict\\jpegblip"), "expected a \\jpegblip")
        XCTAssertTrue(rtf.contains("ffd8ffe0"), "expected the JPEG signature bytes in hex")
    }

    func testRTFPictHasWellFormedHeader() {
        // The \pict carries native size (picw/pich) + display size (picwgoal/pichgoal in twips) so a paste
        // target can size it. (Round-trip through NSAttributedString's RTF reader can't be checked headless -
        // it drops \pict images without a full app/graphics environment - so this asserts the emitted shape.)
        let png = tinyPNG
        let resolver: RichTextImageResolver = { _ in RichTextInlineImage(data: png, format: .png, displaySize: CGSize(width: 10, height: 10)) }
        let rtf = RichTextRTFSerializer.string(from: imageDoc, images: resolver)
        for needle in ["\\pict\\pngblip", "\\picw10", "\\pich10", "\\picwgoal200", "\\pichgoal200"] {
            XCTAssertTrue(rtf.contains(needle), "\\pict missing '\(needle)'")
        }
    }

    func testRTFFallsBackToAltWhenImageNotResolved() {
        let rtf = RichTextRTFSerializer.string(from: imageDoc)   // default resolver returns nil
        XCTAssertFalse(rtf.contains("\\pict"), "should not embed a picture when unresolved")
        XCTAssertTrue(rtf.contains("cat"), "expected the alt text as fallback")
    }

    func testRTFEmbedsGIFStillFrameAsPNG() {
        // RTF can't carry a GIF, but it embeds the still PNG frame - a static image beats none. (HTML still
        // carries the animated GIF.)
        let gif = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])
        let resolver: RichTextImageResolver = { _ in
            RichTextInlineImage(data: gif, format: .gif, displaySize: CGSize(width: 20, height: 20), stillPNG: self.tinyPNG)
        }
        let rtf = RichTextRTFSerializer.string(from: imageDoc, images: resolver)
        XCTAssertTrue(rtf.contains("\\pict\\pngblip"), "GIF should embed its still frame as \\pngblip")
        XCTAssertTrue(rtf.contains("89504e47"), "expected the still PNG bytes, not the GIF bytes")
        XCTAssertFalse(rtf.contains("47494638"), "the GIF bytes must not appear in RTF")
    }

    func testRTFFallsBackToAltForGIFWithoutStill() {
        // If somehow there is no still frame, degrade to alt text rather than emit an invalid \pict.
        let gif = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])
        let resolver: RichTextImageResolver = { _ in RichTextInlineImage(data: gif, format: .gif, displaySize: CGSize(width: 20, height: 20)) }
        let rtf = RichTextRTFSerializer.string(from: imageDoc, images: resolver)
        XCTAssertFalse(rtf.contains("\\pict"), "no still -> no \\pict")
        XCTAssertTrue(rtf.contains("cat"), "expected the alt text fallback")
    }
}
