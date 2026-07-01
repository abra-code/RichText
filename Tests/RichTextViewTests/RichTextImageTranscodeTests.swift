// Tests/RichTextViewTests/RichTextImageTranscodeTests.swift
//
// The copy-embedding transcode (RichTextEmbeddedImage): turns an image's ORIGINAL bytes (handed back by the
// AsyncImageCache store) into the RichTextInlineImage the RTF/HTML serializers embed. PNG/JPEG/GIF keep their
// bytes (GIF also gets a still PNG frame for RTF); any other format is transcoded once by alpha/size. This
// logic lives in RichText, not in the generic cache module.

import XCTest
@testable import RichTextView

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

final class RichTextImageTranscodeTests: XCTestCase {

    private func isPNG(_ data: Data) -> Bool { data.prefix(4).elementsEqual([0x89, 0x50, 0x4E, 0x47]) }
    private func isJPEG(_ data: Data) -> Bool { data.prefix(3).elementsEqual([0xFF, 0xD8, 0xFF]) }

    private func makeImage(width: Int, height: Int, opaque: Bool) -> RTVImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: alpha.rawValue)!
        ctx.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: opaque ? 1.0 : 0.5)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = ctx.makeImage()!
        #if canImport(UIKit)
        return UIImage(cgImage: cg)
        #else
        return NSImage(cgImage: cg, size: CGSize(width: width, height: height))
        #endif
    }

    func testGIFKeptVerbatimWithStillPNG() throws {
        let gif = try XCTUnwrap(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"))
        let inline = try XCTUnwrap(RichTextEmbeddedImage.make(from: gif, pixelSize: CGSize(width: 1, height: 1), maxWidth: 320))
        XCTAssertEqual(inline.format, .gif, "GIF must be kept as GIF, not flattened")
        XCTAssertEqual(inline.data, gif, "GIF bytes must pass through unchanged")
        XCTAssertTrue(isPNG(try XCTUnwrap(inline.stillPNG)), "a real PNG still frame should be produced")
    }

    func testLargeOpaqueTranscodesToJPEG() throws {
        let inline = try XCTUnwrap(RichTextEmbeddedImage.transcode(data: Data([0, 1, 2, 3]),
                                                                   decoded: makeImage(width: 600, height: 600, opaque: true),
                                                                   display: CGSize(width: 300, height: 300)))
        XCTAssertEqual(inline.format, .jpeg, "opaque + large -> JPEG")
        XCTAssertTrue(isJPEG(inline.data))
        XCTAssertNil(inline.stillPNG)
    }

    func testSmallOpaqueTranscodesToPNG() throws {
        let inline = try XCTUnwrap(RichTextEmbeddedImage.transcode(data: Data([0, 1, 2, 3]),
                                                                   decoded: makeImage(width: 16, height: 16, opaque: true),
                                                                   display: CGSize(width: 16, height: 16)))
        XCTAssertEqual(inline.format, .png, "opaque but small -> PNG")
        XCTAssertTrue(isPNG(inline.data))
    }

    func testTransparentTranscodesToPNGEvenWhenLarge() throws {
        let inline = try XCTUnwrap(RichTextEmbeddedImage.transcode(data: Data([0, 1, 2, 3]),
                                                                   decoded: makeImage(width: 600, height: 600, opaque: false),
                                                                   display: CGSize(width: 300, height: 300)))
        XCTAssertEqual(inline.format, .png, "transparent -> PNG regardless of size")
        XCTAssertTrue(isPNG(inline.data))
    }

    func testPNGAndJPEGSourcesPassThroughWithoutDecode() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47] + [UInt8](repeating: 0, count: 8))
        let jpeg = Data([0xFF, 0xD8, 0xFF] + [UInt8](repeating: 0, count: 8))
        let size = CGSize(width: 40, height: 30)
        let p = try XCTUnwrap(RichTextEmbeddedImage.make(from: png, pixelSize: size, maxWidth: 320))
        let j = try XCTUnwrap(RichTextEmbeddedImage.make(from: jpeg, pixelSize: size, maxWidth: 320))
        XCTAssertEqual(p.format, .png)
        XCTAssertEqual(p.data, png, "PNG source kept verbatim (no decode of invalid bytes)")
        XCTAssertEqual(j.format, .jpeg)
        XCTAssertEqual(j.data, jpeg, "JPEG source kept verbatim (no decode of invalid bytes)")
    }

    func testDisplaySizeCapsToMaxWidthPreservingAspect() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47] + [UInt8](repeating: 0, count: 8))
        let inline = try XCTUnwrap(RichTextEmbeddedImage.make(from: png, pixelSize: CGSize(width: 800, height: 400), maxWidth: 320))
        XCTAssertEqual(inline.displaySize.width, 320)
        XCTAssertEqual(inline.displaySize.height, 160)   // 400 * (320 / 800)
    }
}
