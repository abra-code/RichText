// Sources/RichText/Rendering/RichTextImage.swift
//
// Asynchronous image rendering. A Markdown image (![alt](url)) becomes a RichTextImageAttachment - an
// NSTextAttachment that starts as a sized placeholder (so layout reserves space) and, once the bytes are
// fetched, shows the image scaled to a max width. RichTextImageLoading fetches URLs off the main thread
// and caches decoded images in a PROCESS-WIDE cache; the attachment checks that cache at creation, so a
// rebuilt attributed string (SwiftUI re-inits the view freely) shows an already-loaded image immediately
// instead of flashing the placeholder again. When a fetch finishes, a reload closure re-applies cached
// images to the LIVE text storage and re-lays-out - which is why correctness does not depend on the
// SwiftUI view (or its attributed string) being stable across updates.
//
// Attachments are real text-attachment characters, so images stay part of the one selectable text view.
//
// Image LOADING + CACHING (memory + disk, off-main decode/scale) is delegated to the reusable
// AsyncImageCache.ImageStore; this file is only the RichText glue - the attachment, the placeholder, the copy
// representation the serializers embed, and mapping text attachments to store load requests.

import Foundation
import AsyncImageCache

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// An image attachment that is a placeholder until its bytes load, then shows the (width-capped) image.
final class RichTextImageAttachment: NSTextAttachment {
    let url: URL?
    let alt: String
    private(set) var loadedImage: RTVImage?
    private var failed = false
    // Not private: RichTextImageLoading (same file, different type) reads it so every cache lookup / load for
    // this attachment builds the SAME ImageRequest variant (see RichTextImageLoading.imageRequest).
    let maxWidth: CGFloat

    init(alt: String, url: URL?, maxWidth: CGFloat = RichTextImageLoading.defaultMaxWidth) {
        self.alt = alt
        self.url = url
        self.maxWidth = maxWidth
        super.init(data: nil, ofType: nil)
        // If this URL was already fetched (e.g. the attributed string was rebuilt), show it right away.
        // cachedImage gates the scheme (a file: image is never fetched, so it is never in the cache) and uses
        // this attachment's maxWidth so the variant key matches what a load would store.
        if let url, let cached = RichTextImageLoading.cachedImage(for: url, maxWidth: maxWidth) {
            loadedImage = cached
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setImage(_ image: RTVImage) {
        loadedImage = image
        failed = false
        refresh()
    }

    func markFailed() {
        failed = true
        refresh()
    }

    // Drive rendering through the `image` and `bounds` PROPERTIES, not the image(forBounds:) /
    // attachmentBounds(for:) overrides: macOS TextKit 1 draws an attachment from its image/cell property and
    // does NOT reliably call those overrides, so overriding-only renders nothing on macOS (not even the
    // placeholder). Setting the properties works on both platforms and both engines.
    private func refresh() {
        if let loadedImage {
            image = loadedImage
            bounds = CGRect(origin: .zero, size: displaySize(loadedImage))
        } else {
            let size = CGSize(width: min(maxWidth, 240), height: 120)
            image = RichTextImageAttachment.placeholderImage(size: size, alt: alt, failed: failed)
            bounds = CGRect(origin: .zero, size: size)
        }
    }

    private func displaySize(_ image: RTVImage) -> CGSize {
        guard image.size.width > 0 else {
            return CGSize(width: min(maxWidth, 240), height: 120)
        }
        if image.size.width <= maxWidth {
            return image.size
        }
        let scale = maxWidth / image.size.width
        return CGSize(width: maxWidth, height: (image.size.height * scale).rounded())
    }

    // A light rounded box with the alt text, shown while loading or if the load fails.
    private static func placeholderImage(size: CGSize, alt: String, failed: Bool) -> RTVImage? {
        guard size.width > 1, size.height > 1 else {
            return nil
        }
        let rect = CGRect(origin: .zero, size: size)
        let label = failed ? (alt.isEmpty ? "image unavailable" : "\(alt) (unavailable)") : (alt.isEmpty ? "loading image..." : alt)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: RTVFont.systemFont(ofSize: 12),
            .foregroundColor: RTVColors.secondary,
            .paragraphStyle: paragraph,
        ]
        let text = NSAttributedString(string: label, attributes: attributes)
        let inset = rect.insetBy(dx: 8, dy: max(0, (size.height - 16) / 2))

        let draw: () -> Void = {
            fillRoundedRect(rect.insetBy(dx: 0.5, dy: 0.5), radius: 6, color: RTVColors.codeFill)
            #if canImport(AppKit)
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            border.lineWidth = 1
            RTVColors.separator.setStroke()
            border.stroke()
            #else
            let border = UIBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 6)
            border.lineWidth = 1
            RTVColors.separator.setStroke()
            border.stroke()
            #endif
            text.draw(with: inset, options: [.usesLineFragmentOrigin], context: nil)
        }

        #if canImport(UIKit)
        return UIGraphicsImageRenderer(size: size).image { _ in draw() }
        #else
        let image = NSImage(size: size)
        image.lockFocus()
        draw()
        image.unlockFocus()
        return image
        #endif
    }
}

/// Loads and caches images for the attachments in a rendered document. Stateless from the view's point of
/// view: the cache is process-wide and the reload closure operates on the live text storage, so it does
/// not matter how often SwiftUI rebuilds the view or its attributed string.
/// An embeddable image encoding whose ORIGINAL bytes travel unchanged. PNG and JPEG go into both RTF
/// (\pngblip / \jpegblip) and HTML (data: URIs). GIF goes into HTML only - RTF's \pict has no GIF blip - but
/// it is kept verbatim so ANIMATED GIFs survive to HTML targets rather than being flattened to a still PNG.
/// (Other source formats are transcoded to PNG/JPEG on the way in.)
public enum RichTextImageFormat: Sendable {
    case png
    case jpeg
    case gif

    public var mimeType: String {
        switch self {
        case .png: return "image/png"
        case .jpeg: return "image/jpeg"
        case .gif: return "image/gif"
        }
    }

    /// The RTF \pict blip control word, or nil if RTF cannot carry this format (GIF).
    var rtfBlip: String? {
        switch self {
        case .png: return "\\pngblip"
        case .jpeg: return "\\jpegblip"
        case .gif: return nil
        }
    }
}

/// The (original) bytes + format + intended display size of a loaded image, used to embed it into copied
/// RTF / HTML so the picture survives paste into other rich editors (a loaded image only - unloaded ones
/// fall back to the URL / alt text).
public struct RichTextInlineImage: Sendable {
    public let data: Data            // original encoded bytes (not re-encoded for PNG/JPEG/GIF)
    public let format: RichTextImageFormat
    public let displaySize: CGSize   // points, capped to the on-screen max width
    /// A still PNG frame for consumers that cannot carry `format` (RTF with a GIF): a static image beats
    /// none. nil when `format` is embeddable everywhere (PNG/JPEG).
    public let stillPNG: Data?

    public init(data: Data, format: RichTextImageFormat, displaySize: CGSize, stillPNG: Data? = nil) {
        self.data = data
        self.format = format
        self.displaySize = displaySize
        self.stillPNG = stillPNG
    }
}

/// Resolves an image URL to its loaded bytes, for embedding in copied RTF/HTML. Returns nil for images that
/// are not loaded (they fall back to the URL / alt text). The serializers default to a resolver that returns
/// nil for everything, so callers that do not care about embedded images are unaffected.
public typealias RichTextImageResolver = (String) -> RichTextInlineImage?

@MainActor
enum RichTextImageLoading {
    // Loading + caching (memory + disk, off-main decode) is delegated to AsyncImageCache.ImageStore. This
    // enum is the glue that maps text attachments to store load requests and re-applies loaded images to the
    // live text storage. `inFlight` avoids spawning redundant load Tasks (the store also de-duplicates).
    private static var inFlight = Set<URL>()

    // The default on-screen display cap (points) for an inline image; also the attachment's default maxWidth.
    nonisolated static let defaultMaxWidth: CGFloat = 320

    // The SINGLE place that builds a store request for an inline image, so every lookup and the load for a
    // given URL share ONE variant key (ImageRequest.variantKey includes targetWidth; a mismatch between the
    // stored variant and a lookup = permanent cache miss => images reload forever / never display).
    //
    // targetWidth caps the decode/downscale so a multi-megapixel source is scaled down instead of decoded at
    // full natural resolution (a decompression-bomb / OOM defense). maxWidth is a POINT cap; targetWidth is in
    // PIXELS - we map 1:1 (the point value IS the pixel cap). This is deliberately scale-INDEPENDENT: the
    // variant key must be byte-identical at every call site, and the live screen scale is not safely readable
    // from the nonisolated lookups below. Trade-off: on a 2x/3x display the image is decoded at the point
    // width and upscaled a little for presentation (slightly soft); raising this to a fixed multiple is safe
    // ONLY if the SAME multiple is applied here (all call sites route through this one helper, so they would).
    nonisolated static func imageRequest(for url: URL, maxWidth: CGFloat) -> ImageRequest {
        return ImageRequest(url: url, targetWidth: maxWidth)
    }

    nonisolated static func cachedImage(for url: URL, maxWidth: CGFloat = defaultMaxWidth) -> RTVImage? {
        // Disallowed schemes (file:, javascript:, ...) are never loaded, so never cached - short-circuit.
        guard RichTextURLPolicy.allowsImage(url) else {
            return nil
        }
        return ImageStore.shared.cachedImage(for: imageRequest(for: url, maxWidth: maxWidth))
    }

    /// The embeddable bytes + format + display size of an already-loaded image, or nil if not loaded. Used by
    /// the serializers to embed the picture in copied RTF/HTML - sourced from the store's original-bytes cache
    /// (PNG/JPEG/GIF kept verbatim; other formats were transcoded once at load time).
    nonisolated static func cachedInlineImage(for url: URL, maxWidth: CGFloat = defaultMaxWidth) -> RichTextInlineImage? {
        // Defense in depth at the embed boundary: only allow-listed image schemes are embeddable. (Loads are
        // already gated, so a disallowed scheme is never in the cache - but this makes the rule explicit here.)
        // This path embeds the ORIGINAL bytes (variant-width-independent), so it does not build an ImageRequest.
        guard RichTextURLPolicy.allowsImage(url), let original = ImageStore.shared.cachedOriginalBytes(for: url) else {
            return nil
        }
        // Transcode lazily, from the cache's ORIGINAL bytes - the cache stays generic (no copy concerns).
        return RichTextEmbeddedImage.make(from: original.data, pixelSize: original.pixelSize, maxWidth: maxWidth)
    }

    /// Apply any cached images to the not-yet-loaded image attachments in `content` (a rendered attributed
    /// string or a live NSTextStorage). Returns true if it changed anything.
    @discardableResult
    static func applyCached(in content: NSAttributedString) -> Bool {
        var changed = false
        content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length)) { value, _, _ in
            guard let attachment = value as? RichTextImageAttachment, attachment.loadedImage == nil,
                  let url = attachment.url, RichTextURLPolicy.allowsImage(url),
                  let image = ImageStore.shared.cachedImage(for: imageRequest(for: url, maxWidth: attachment.maxWidth)) else {
                return
            }
            attachment.setImage(image)
            changed = true
        }
        return changed
    }

    /// Start loading every not-yet-cached image URL in `content`. `reload` is called on the main actor after
    /// each load finishes (it should re-apply cached images to the live storage and re-lay-out).
    static func startLoading(in content: NSAttributedString, reload: @escaping @MainActor () -> Void) {
        applyCached(in: content)
        content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length)) { value, _, _ in
            // Gate the scheme here so a disallowed URL (file:, javascript:, ...) is never fetched from
            // disk/network - the attachment stays in its placeholder state. maxWidth aligns the cache-check
            // and the load variant key with the attachment's stored variant (see imageRequest).
            guard let attachment = value as? RichTextImageAttachment, attachment.loadedImage == nil,
                  let url = attachment.url, RichTextURLPolicy.allowsImage(url),
                  ImageStore.shared.cachedImage(for: imageRequest(for: url, maxWidth: attachment.maxWidth)) == nil,
                  !inFlight.contains(url) else {
                return
            }
            let maxWidth = attachment.maxWidth
            inFlight.insert(url)
            Task {
                let image = await load(url, maxWidth: maxWidth)
                inFlight.remove(url)
                if image == nil {
                    attachment.markFailed()
                }
                applyCached(in: content)
                reload()
            }
        }
    }

    // Bridge the store's completion-based load into async so the surrounding Task stays on the main actor.
    // maxWidth is threaded through so the LOAD stores the same variant the lookups above check for.
    private static func load(_ url: URL, maxWidth: CGFloat) async -> RTVImage? {
        return await withCheckedContinuation { continuation in
            ImageStore.shared.load(imageRequest(for: url, maxWidth: maxWidth)) { image in
                continuation.resume(returning: image)
            }
        }
    }

}
