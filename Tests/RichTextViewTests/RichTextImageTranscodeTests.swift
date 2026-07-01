// Tests/RichTextViewTests/RichTextImageTranscodeTests.swift
//
// Exercises the transcode path in RichTextImageLoading.embeddableBytes for a source that is neither PNG nor
// JPEG (a real GIF), plus the alpha/size branches that pick PNG vs JPEG. PNG/JPEG sources are kept verbatim;
// everything else is re-encoded once - PNG if transparent or small, JPEG only if opaque AND large.

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

    // An opaque or translucent solid-color image at an exact pixel size, built via CoreGraphics so the alpha
    // info the encoder sees is exactly what we asked for.
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

    // A real (uncommon) source format: the classic 1x1 transparent GIF. A GIF is kept VERBATIM (so animated
    // GIFs survive to HTML) - not flattened to PNG - and RTF cannot carry it.
    func testGIFSourceIsKeptVerbatim() throws {
        let gif = try XCTUnwrap(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"))
        XCTAssertEqual(Array(gif.prefix(3)), [0x47, 0x49, 0x46], "fixture should be a GIF")   // 'G' 'I' 'F'
        let image = try XCTUnwrap(RTVImage(data: gif), "GIF should decode on this platform")
        let bytes = try XCTUnwrap(RichTextImageLoading.embeddableBytes(from: gif, decoded: image))
        XCTAssertEqual(bytes.format, .gif, "GIF must be kept as GIF, not flattened")
        XCTAssertEqual(bytes.data, gif, "the original GIF bytes must pass through unchanged")
        XCTAssertNil(bytes.format.rtfBlip, "RTF's \\pict cannot carry GIF")
        let still = try XCTUnwrap(bytes.stillPNG, "a still PNG frame should be produced for RTF")
        XCTAssertTrue(isPNG(still), "the still frame should be real PNG bytes")
    }

    func testLargeOpaqueTranscodesToJPEG() throws {
        let image = makeImage(width: 600, height: 600, opaque: true)   // > 512x512 -> photo-ish
        let bytes = try XCTUnwrap(RichTextImageLoading.embeddableBytes(from: Data([0, 1, 2, 3]), decoded: image))
        XCTAssertEqual(bytes.format, .jpeg, "opaque + large -> JPEG (compact)")
        XCTAssertTrue(isJPEG(bytes.data), "output should be real JPEG bytes")
    }

    func testSmallOpaqueTranscodesToPNG() throws {
        let image = makeImage(width: 16, height: 16, opaque: true)     // below the size threshold
        let bytes = try XCTUnwrap(RichTextImageLoading.embeddableBytes(from: Data([0, 1, 2, 3]), decoded: image))
        XCTAssertEqual(bytes.format, .png, "opaque but small (icon/graphic) -> PNG (crisp)")
        XCTAssertTrue(isPNG(bytes.data))
    }

    func testTransparentTranscodesToPNGEvenWhenLarge() throws {
        let image = makeImage(width: 600, height: 600, opaque: false)  // has alpha
        let bytes = try XCTUnwrap(RichTextImageLoading.embeddableBytes(from: Data([0, 1, 2, 3]), decoded: image))
        XCTAssertEqual(bytes.format, .png, "transparent -> PNG regardless of size (JPEG has no alpha)")
        XCTAssertTrue(isPNG(bytes.data))
    }

    func testPNGAndJPEGSourcesPassThroughUnchanged() throws {
        let image = makeImage(width: 8, height: 8, opaque: true)
        let png = Data([0x89, 0x50, 0x4E, 0x47] + [UInt8](repeating: 0, count: 8))
        let jpeg = Data([0xFF, 0xD8, 0xFF] + [UInt8](repeating: 0, count: 8))
        let pngBytes = try XCTUnwrap(RichTextImageLoading.embeddableBytes(from: png, decoded: image))
        let jpegBytes = try XCTUnwrap(RichTextImageLoading.embeddableBytes(from: jpeg, decoded: image))
        XCTAssertEqual(pngBytes.format, .png)
        XCTAssertEqual(pngBytes.data, png, "PNG source kept verbatim")
        XCTAssertEqual(jpegBytes.format, .jpeg)
        XCTAssertEqual(jpegBytes.data, jpeg, "JPEG source kept verbatim")
    }
}
