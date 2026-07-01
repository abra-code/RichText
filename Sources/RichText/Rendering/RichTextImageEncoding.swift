// Sources/RichText/Rendering/RichTextImageEncoding.swift
//
// Produces the embeddable COPY representation (RichTextInlineImage) from an image's ORIGINAL transport bytes.
// This is a copy / serialization concern - deciding PNG vs JPEG for embedding, and computing a GIF still
// frame because RTF's \pict cannot carry a GIF - so it lives with RichText, NOT in the generic
// AsyncImageCache. The cache hands back the original bytes + natural pixel size; this turns them into what
// the RTF / HTML serializers embed. It is invoked lazily, only when a copy actually happens (a one-shot user
// action), so the display / cache path never pays for it.

import Foundation

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

enum RichTextEmbeddedImage {

    // Opaque images with MORE pixels than this transcode to JPEG (photos); smaller opaque images stay PNG
    // (crisp icons/graphics, where JPEG would ring on hard edges). ~0.25 MP. Transparent images are always
    // PNG regardless of size (JPEG has no alpha).
    static let opaqueJPEGThresholdPixels = 512 * 512

    /// The embeddable image for `data` (the original transport bytes) at a display size capped to `maxWidth`.
    /// PNG / JPEG keep their bytes with NO decode; GIF keeps its bytes plus a still PNG frame; any other
    /// format is decoded and transcoded once (PNG if it has alpha or is small, JPEG if opaque AND large).
    /// Returns nil when nothing embeddable can be produced.
    static func make(from data: Data, pixelSize: CGSize, maxWidth: CGFloat) -> RichTextInlineImage? {
        let display = cappedSize(pixelSize, maxWidth: maxWidth)
        if hasPrefix(data, [0x89, 0x50, 0x4E, 0x47]) {           // \x89 P N G - no decode needed
            return RichTextInlineImage(data: data, format: .png, displaySize: display, stillPNG: nil)
        }
        if hasPrefix(data, [0xFF, 0xD8, 0xFF]) {                 // JPEG SOI - no decode needed
            return RichTextInlineImage(data: data, format: .jpeg, displaySize: display, stillPNG: nil)
        }
        // GIF / uncommon formats: decode (only reached at copy time) and pick an embeddable encoding.
        guard let image = RTVImage(data: data) else {
            return nil
        }
        return transcode(data: data, decoded: image, display: display)
    }

    // Choose the embeddable encoding for a decoded image (the original `data` is used only to detect GIF).
    // Internal so the format / alpha / size decisions are unit-testable with constructed images.
    static func transcode(data: Data, decoded image: RTVImage, display: CGSize) -> RichTextInlineImage? {
        if hasPrefix(data, [0x47, 0x49, 0x46, 0x38]) {           // "GIF8" (87a / 89a)
            return RichTextInlineImage(data: data, format: .gif, displaySize: display, stillPNG: pngData(image))
        }
        let cg = cgImage(image)
        let opaque = cg.map(isOpaque) ?? false                   // unknown -> treat as transparent (safe: PNG)
        let pixels = cg.map { $0.width * $0.height } ?? 0
        if opaque, pixels > opaqueJPEGThresholdPixels, let jpeg = jpegData(image) {
            return RichTextInlineImage(data: jpeg, format: .jpeg, displaySize: display, stillPNG: nil)
        }
        if let png = pngData(image) {
            return RichTextInlineImage(data: png, format: .png, displaySize: display, stillPNG: nil)
        }
        if let jpeg = jpegData(image) {
            return RichTextInlineImage(data: jpeg, format: .jpeg, displaySize: display, stillPNG: nil)
        }
        return nil
    }

    // MARK: - Helpers (internal so the transcode is unit-testable)

    static func hasPrefix(_ data: Data, _ bytes: [UInt8]) -> Bool {
        guard data.count >= bytes.count else {
            return false
        }
        return Array(data.prefix(bytes.count)) == bytes
    }

    static func cappedSize(_ size: CGSize, maxWidth: CGFloat) -> CGSize {
        guard size.width > maxWidth, size.width > 0 else {
            return size
        }
        let scale = maxWidth / size.width
        return CGSize(width: maxWidth, height: (size.height * scale).rounded())
    }

    private static func cgImage(_ image: RTVImage) -> CGImage? {
        #if canImport(UIKit)
        return image.cgImage
        #else
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }

    private static func isOpaque(_ cg: CGImage) -> Bool {
        switch cg.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return true
        default:
            return false
        }
    }

    private static func pngData(_ image: RTVImage) -> Data? {
        #if canImport(UIKit)
        return image.pngData()
        #else
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
        #endif
    }

    private static func jpegData(_ image: RTVImage, quality: CGFloat = 0.85) -> Data? {
        #if canImport(UIKit)
        return image.jpegData(compressionQuality: quality)
        #else
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        #endif
    }
}
