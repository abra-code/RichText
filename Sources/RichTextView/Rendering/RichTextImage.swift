// Sources/RichTextView/Rendering/RichTextImage.swift
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
// Attachments are real text-attachment characters, so images stay part of the one selectable text view
// (copy still goes through the serializers - embedding image bytes on the pasteboard is a follow-up).

import Foundation

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
    private let maxWidth: CGFloat

    init(alt: String, url: URL?, maxWidth: CGFloat = 320) {
        self.alt = alt
        self.url = url
        self.maxWidth = maxWidth
        super.init(data: nil, ofType: nil)
        // If this URL was already fetched (e.g. the attributed string was rebuilt), show it right away.
        if let url, let cached = RichTextImageLoading.cachedImage(for: url) {
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

/// The original bytes + format + natural size of a fetched image, cached for copy embedding. Keeping the
/// ORIGINAL encoded bytes (rather than re-encoding the decoded image to PNG) is what keeps photos small:
/// a JPEG stays a JPEG. A reference type because NSCache stores objects.
final class RichTextCachedBytes {
    let data: Data
    let format: RichTextImageFormat
    let naturalSize: CGSize
    let stillPNG: Data?
    init(data: Data, format: RichTextImageFormat, naturalSize: CGSize, stillPNG: Data? = nil) {
        self.data = data
        self.format = format
        self.naturalSize = naturalSize
        self.stillPNG = stillPNG
    }
}

@MainActor
enum RichTextImageLoading {
    // NSCache is internally thread-safe, so it can be read from an attachment's init on any actor.
    nonisolated(unsafe) private static let cache = NSCache<NSURL, RTVImage>()
    nonisolated(unsafe) private static let bytesCache = NSCache<NSURL, RichTextCachedBytes>()
    private static var inFlight = Set<URL>()

    nonisolated static func cachedImage(for url: URL) -> RTVImage? {
        return cache.object(forKey: url as NSURL)
    }

    /// The embeddable bytes + format + display size of an already-loaded image, or nil if not loaded. Used by
    /// the serializers to embed the picture in copied RTF/HTML. No decode/re-encode on this path - it returns
    /// the cached original bytes (PNG/JPEG untouched; other formats were transcoded to PNG at fetch time).
    nonisolated static func cachedInlineImage(for url: URL, maxWidth: CGFloat = 320) -> RichTextInlineImage? {
        guard let bytes = bytesCache.object(forKey: url as NSURL) else {
            return nil
        }
        return RichTextInlineImage(data: bytes.data, format: bytes.format,
                                   displaySize: cappedSize(bytes.naturalSize, maxWidth: maxWidth),
                                   stillPNG: bytes.stillPNG)
    }

    // Opaque images with MORE pixels than this transcode to JPEG (photos); smaller opaque images stay PNG
    // (icons / small graphics, where PNG is crisp and already small, and JPEG would add ringing on hard
    // edges). ~0.25 MP (512x512). Transparent images are always PNG regardless of size (JPEG has no alpha).
    nonisolated private static let opaqueJPEGThresholdPixels = 512 * 512

    // Choose the embeddable encoding. Keep the ORIGINAL bytes for PNG / JPEG / GIF (detected by magic number)
    // so photos stay small and animated GIFs stay animated. Anything else (HEIC/WebP/TIFF/BMP/...) is
    // transcoded ONCE, at fetch time - PNG if it has alpha or is small, JPEG if it is opaque AND large (a
    // photo). We never emit TIFF (the old macOS pasteboard default) - only PNG/JPEG/GIF travel.
    // Internal (not private) so it can be unit-tested with an uncommon source format.
    nonisolated static func embeddableBytes(from data: Data, decoded image: RTVImage) -> RichTextCachedBytes? {
        if hasPrefix(data, [0x89, 0x50, 0x4E, 0x47]) {           // \x89 P N G
            return RichTextCachedBytes(data: data, format: .png, naturalSize: image.size)
        }
        if hasPrefix(data, [0xFF, 0xD8, 0xFF]) {                 // JPEG SOI
            return RichTextCachedBytes(data: data, format: .jpeg, naturalSize: image.size)
        }
        if hasPrefix(data, [0x47, 0x49, 0x46, 0x38]) {           // "GIF8" (87a / 89a)
            // Keep the GIF verbatim for HTML (animation), plus a still PNG (the decoded frame) for RTF, which
            // has no GIF blip - a static image beats none.
            return RichTextCachedBytes(data: data, format: .gif, naturalSize: image.size, stillPNG: pngData(image))
        }
        let cg = cgImage(image)
        let opaque = cg.map(isOpaque) ?? false                   // unknown -> treat as transparent (safe: PNG)
        let pixels = cg.map { $0.width * $0.height } ?? 0
        if opaque, pixels > opaqueJPEGThresholdPixels, let jpeg = jpegData(image) {
            return RichTextCachedBytes(data: jpeg, format: .jpeg, naturalSize: image.size)
        }
        if let png = pngData(image) {
            return RichTextCachedBytes(data: png, format: .png, naturalSize: image.size)
        }
        if let jpeg = jpegData(image) {
            return RichTextCachedBytes(data: jpeg, format: .jpeg, naturalSize: image.size)
        }
        return nil   // could not produce PNG/JPEG - do not embed; copy falls back to the URL / alt text
    }

    nonisolated private static func hasPrefix(_ data: Data, _ bytes: [UInt8]) -> Bool {
        guard data.count >= bytes.count else {
            return false
        }
        return Array(data.prefix(bytes.count)) == bytes
    }

    nonisolated private static func cgImage(_ image: RTVImage) -> CGImage? {
        #if canImport(UIKit)
        return image.cgImage
        #else
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }

    // Opaque = no (used) alpha channel; such images are safe to encode as JPEG.
    nonisolated private static func isOpaque(_ cg: CGImage) -> Bool {
        switch cg.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return true
        default:
            return false
        }
    }

    nonisolated private static func pngData(_ image: RTVImage) -> Data? {
        #if canImport(UIKit)
        return image.pngData()
        #else
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
        #endif
    }

    nonisolated private static func jpegData(_ image: RTVImage, quality: CGFloat = 0.85) -> Data? {
        #if canImport(UIKit)
        return image.jpegData(compressionQuality: quality)
        #else
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        #endif
    }

    nonisolated private static func cappedSize(_ size: CGSize, maxWidth: CGFloat) -> CGSize {
        guard size.width > maxWidth, size.width > 0 else {
            return size
        }
        let scale = maxWidth / size.width
        return CGSize(width: maxWidth, height: (size.height * scale).rounded())
    }

    /// Apply any cached images to the not-yet-loaded image attachments in `content` (a rendered attributed
    /// string or a live NSTextStorage). Returns true if it changed anything.
    @discardableResult
    static func applyCached(in content: NSAttributedString) -> Bool {
        var changed = false
        content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length)) { value, _, _ in
            guard let attachment = value as? RichTextImageAttachment, attachment.loadedImage == nil,
                  let url = attachment.url, let image = cache.object(forKey: url as NSURL) else {
                return
            }
            attachment.setImage(image)
            changed = true
        }
        return changed
    }

    /// Start fetching every not-yet-cached image URL in `content`. `reload` is called on the main actor
    /// after each fetch completes (it should re-apply cached images to the live storage and re-lay-out).
    static func startLoading(in content: NSAttributedString, reload: @escaping @MainActor () -> Void) {
        applyCached(in: content)
        content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length)) { value, _, _ in
            guard let attachment = value as? RichTextImageAttachment, attachment.loadedImage == nil,
                  let url = attachment.url, cache.object(forKey: url as NSURL) == nil, !inFlight.contains(url) else {
                return
            }
            inFlight.insert(url)
            Task {
                let image = await RichTextImageLoading.fetch(url)
                inFlight.remove(url)
                if let image {
                    cache.setObject(image, forKey: url as NSURL)
                    attachment.setImage(image)
                } else {
                    attachment.markFailed()
                }
                reload()
            }
        }
    }

    private nonisolated static func fetch(_ url: URL) async -> RTVImage? {
        let data: Data?
        switch url.scheme {
        case "data", "file":
            // data: URIs (base64) and local files decode without the network.
            data = try? Data(contentsOf: url)
        default:
            data = try? await URLSession.shared.data(from: url).0
        }
        guard let data, let image = RTVImage(data: data) else {
            return nil
        }
        // Stash the embeddable bytes + format so copy can embed them without re-encoding (photos stay small).
        if let bytes = embeddableBytes(from: data, decoded: image) {
            bytesCache.setObject(bytes, forKey: url as NSURL)
        }
        return image
    }
}
