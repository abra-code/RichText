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

/// Why an image that is not loaded is not being fetched (see RichTextRemoteImages).
enum RichTextImageHold: Equatable {
    /// Not held: loading, failed, or about to load.
    case none
    /// A remote image under `.onClick`: fetched when the user clicks (taps) its placeholder.
    case awaitingClick
    /// A remote image under `.never`.
    case off
}

/// An image attachment that is a placeholder until its bytes load, then shows the (width-capped) image.
final class RichTextImageAttachment: NSTextAttachment {
    let url: URL?
    let alt: String
    private(set) var loadedImage: RTVImage?
    private var failed = false
    private(set) var hold: RichTextImageHold = .none
    // Set by a click on the held placeholder, so a later loading pass under `.onClick` fetches this
    // attachment instead of holding it again.
    var approved = false
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
        hold = .none
        refresh()
    }

    /// Hold (or release) a not-yet-loaded image. Returns true when the placeholder changed and needs a redraw.
    @discardableResult
    func setHold(_ newHold: RichTextImageHold) -> Bool {
        guard loadedImage == nil, hold != newHold else {
            return false
        }
        hold = newHold
        refresh()
        return true
    }

    var hasFailed: Bool {
        return failed
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
            let label = RichTextImageAttachment.placeholderLabel(alt: alt, url: url, failed: failed, hold: hold)
            image = RichTextImageAttachment.placeholderImage(size: size, label: label)
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

    /// The placeholder's text: the alt text while loading or after a failure; for a held remote image, the alt
    /// text over a second line naming the image's host, so the user sees where a click would send a request.
    static func placeholderLabel(alt: String, url: URL?, failed: Bool, hold: RichTextImageHold) -> String {
        // The host as written, percent escapes kept: a decoded host could show an escaped "/" or line break
        // and pass one domain off as another.
        let host = url?.host(percentEncoded: true) ?? "the web"
        switch hold {
        case .awaitingClick:
            #if canImport(AppKit)
            let action = "Click"
            #else
            let action = "Tap"
            #endif
            return "\(alt.isEmpty ? "Image" : alt)\n\(action) to load from \(host)"
        case .off:
            return "\(alt.isEmpty ? "Image" : alt)\nNot loaded from \(host): remote images are off"
        case .none:
            if failed {
                return alt.isEmpty ? "image unavailable" : "\(alt) (unavailable)"
            }
            return alt.isEmpty ? "loading image..." : alt
        }
    }

    // A light rounded box with the label, one paragraph per line, each truncated rather than wrapped.
    private static func placeholderImage(size: CGSize, label: String) -> RTVImage? {
        guard size.width > 1, size.height > 1 else {
            return nil
        }
        let rect = CGRect(origin: .zero, size: size)
        let lineCount = CGFloat(label.split(separator: "\n", omittingEmptySubsequences: false).count)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: RTVFont.systemFont(ofSize: 12),
            .foregroundColor: RTVColors.secondary,
            .paragraphStyle: paragraph,
        ]
        let text = NSMutableAttributedString(string: label, attributes: attributes)
        // The last line of a held image's label names the host a click would contact. Truncate it in the
        // middle, so a long host keeps its right end - the domain that receives the request - on screen: at
        // the tail, "https://apple.com.images.chart.collector.example/" shows as "...from apple.com.images.c...".
        let lastBreak = (label as NSString).range(of: "\n", options: .backwards)
        if lastBreak.location != NSNotFound {
            let hostParagraph = NSMutableParagraphStyle()
            hostParagraph.alignment = .center
            hostParagraph.lineBreakMode = .byTruncatingMiddle
            text.addAttribute(.paragraphStyle, value: hostParagraph,
                              range: NSRange(location: NSMaxRange(lastBreak), length: text.length - NSMaxRange(lastBreak)))
        }
        let inset = rect.insetBy(dx: 8, dy: max(0, (size.height - 16 * lineCount) / 2))

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
    // live text storage.
    //
    // One fetch per URL at a time, and EVERY document that needs the URL meanwhile waits on that one fetch:
    // `waiting` maps each URL being fetched to the documents to update when it ends. A document that found
    // the fetch already running used to be skipped and never told, so when several views showed the same
    // image at once (the same inline image in three documents, the same picture in two messages) only the
    // first showed it; the rest kept their placeholder until SwiftUI happened to rebuild them.
    private static var waiting: [URL: [(content: NSAttributedString, reload: @MainActor () -> Void)]] = [:]

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

    /// Start loading every not-yet-cached image URL in `content`, as `remoteImages` allows: under `.onClick`
    /// and `.never` a remote (http / https) image is held with a placeholder instead of fetched, unless (under
    /// `.onClick` only) the user already clicked it. `reload` is called on the main actor after each load
    /// finishes, and once more when this pass changed a placeholder (it should re-apply cached images to the
    /// live storage and re-lay-out).
    static func startLoading(in content: NSAttributedString, remoteImages: RichTextRemoteImages = .automatic,
                             reload: @escaping @MainActor () -> Void) {
        applyCached(in: content)
        var placeholderChanged = false
        content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length)) { value, _, _ in
            // Gate the scheme here so a disallowed URL (file:, javascript:, ...) is never fetched from
            // disk/network - the attachment stays in its placeholder state.
            guard let attachment = value as? RichTextImageAttachment, attachment.loadedImage == nil,
                  let url = attachment.url, RichTextURLPolicy.allowsImage(url) else {
                return
            }
            // A click approved the image under .onClick; it does not outlive a switch to .never (a clicked
            // image whose fetch failed would otherwise be fetched again here).
            let held = remoteImages == .never || (remoteImages == .onClick && !attachment.approved)
            if RichTextURLPolicy.isRemoteImage(url), held {
                if attachment.setHold(remoteImages == .onClick ? .awaitingClick : .off) {
                    placeholderChanged = true
                }
                return
            }
            if attachment.setHold(.none) {
                placeholderChanged = true
            }
            fetch(attachment, url: url, in: content, reload: reload)
        }
        if placeholderChanged {
            reload()
        }
    }

    /// A click (tap) on a held image's placeholder: fetch that image, and remember the click so later loading
    /// passes over the same attachment fetch it too. Returns false, doing nothing, when the attachment was not
    /// waiting for a click.
    @discardableResult
    static func loadOnClick(_ attachment: RichTextImageAttachment, in content: NSAttributedString,
                            reload: @escaping @MainActor () -> Void) -> Bool {
        guard attachment.hold == .awaitingClick, let url = attachment.url, RichTextURLPolicy.allowsImage(url) else {
            return false
        }
        attachment.approved = true
        attachment.setHold(.none)
        fetch(attachment, url: url, in: content, reload: reload)
        reload()
        return true
    }

    /// Whether a fetch of `url` is running (for tests).
    static func isFetching(_ url: URL) -> Bool {
        return waiting[url] != nil
    }

    // Fetch one attachment's image unless it is cached; if a fetch of the URL is already running, wait on it
    // instead. When it ends, every waiting document gets the image (or, on failure, its not-yet-loaded
    // attachments of that URL say so) and its view is reloaded. maxWidth aligns the cache-check and the load
    // variant key with the attachment's stored variant (see imageRequest).
    private static func fetch(_ attachment: RichTextImageAttachment, url: URL, in content: NSAttributedString,
                              reload: @escaping @MainActor () -> Void) {
        guard ImageStore.shared.cachedImage(for: imageRequest(for: url, maxWidth: attachment.maxWidth)) == nil else {
            return
        }
        if let documents = waiting[url] {
            // One entry per document: a document using the image twice is updated once.
            if !documents.contains(where: { $0.content === content }) {
                waiting[url]?.append((content, reload))
            }
            return
        }
        waiting[url] = [(content, reload)]
        let maxWidth = attachment.maxWidth
        Task {
            let image = await load(url, maxWidth: maxWidth)
            let documents = waiting.removeValue(forKey: url) ?? []
            for document in documents {
                if image == nil {
                    markFailed(url, in: document.content)
                }
                applyCached(in: document.content)
                document.reload()
            }
        }
    }

    // After a failed fetch: every attachment of `url` in `content` still waiting for it says it is unavailable.
    // Held attachments keep their "click to load" placeholder; they were never waiting.
    private static func markFailed(_ url: URL, in content: NSAttributedString) {
        content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length)) { value, _, _ in
            if let attachment = value as? RichTextImageAttachment, attachment.url == url,
               attachment.loadedImage == nil, attachment.hold == .none {
                attachment.markFailed()
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

extension RichTextImageLoading {
    /// The held attachments of `content` that wait for a click, with their character indexes.
    static func attachmentsAwaitingClick(in content: NSAttributedString) -> [(index: Int, attachment: RichTextImageAttachment)] {
        var found: [(index: Int, attachment: RichTextImageAttachment)] = []
        content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length)) { value, range, _ in
            if let attachment = value as? RichTextImageAttachment, attachment.hold == .awaitingClick {
                found.append((range.location, attachment))
            }
        }
        return found
    }
}

#if canImport(AppKit)

extension RichTextImageLoading {
    /// The image attachment under `point` (in `textView`'s coordinates) whose placeholder waits for a click,
    /// or nil. Each held attachment's own rectangle is tested, rather than the character nearest the point:
    /// TextKit 2 answers an insertion-index query with the end of the document until the view has been laid
    /// out for display, and a document holds few images.
    static func heldAttachment(at point: CGPoint, in textView: NSTextView) -> RichTextImageAttachment? {
        guard let storage = textView.textStorage, let window = textView.window else {
            return nil
        }
        for (index, attachment) in attachmentsAwaitingClick(in: storage) {
            let screenRect = textView.firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)
            let rect = textView.convert(window.convertFromScreen(screenRect), from: nil)
            if rect.contains(point) {
                return attachment
            }
        }
        return nil
    }
}

/// A RichText text view that loads a held image when its placeholder is clicked (RichTextRemoteImages.onClick).
@MainActor
protocol RichTextHeldImageClicking: NSTextView {
    var onHeldImageClick: ((RichTextImageAttachment) -> Void)? { get set }
}

extension RichTextHeldImageClicking {
    /// Call first in mouseDown: true when the press began on a held image and has been handled. The image
    /// is fetched only on a completed click - the mouse released on the same placeholder, with no modifier
    /// keys - so a drag that starts on a placeholder, or a Control-click for the menu, sends nothing. A
    /// press with modifiers is left to the text view (Shift extends a selection, Control opens the menu).
    func handleHeldImageClick(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        guard let onHeldImageClick, modifiers.isEmpty,
              let attachment = RichTextImageLoading.heldAttachment(at: convert(event.locationInWindow, from: nil), in: self) else {
            return false
        }
        // The usual NSView tracking loop: consume the press until the button comes up.
        var release: NSEvent?
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp {
                release = next
                break
            }
        }
        if let release,
           RichTextImageLoading.heldAttachment(at: convert(release.locationInWindow, from: nil), in: self) === attachment {
            onHeldImageClick(attachment)
        }
        return true
    }
}

#elseif canImport(UIKit)

extension RichTextImageLoading {
    /// The image attachment under `point` (in `textView`'s coordinates) whose placeholder waits for a tap,
    /// or nil. The point must fall inside the attachment's own rectangle, not merely nearest to it.
    static func heldAttachment(at point: CGPoint, in textView: UITextView) -> RichTextImageAttachment? {
        // See the AppKit twin for why each held attachment is tested rather than the nearest character.
        for (index, attachment) in attachmentsAwaitingClick(in: textView.textStorage) {
            guard let start = textView.position(from: textView.beginningOfDocument, offset: index),
                  let end = textView.position(from: start, offset: 1),
                  let range = textView.textRange(from: start, to: end) else {
                continue
            }
            if textView.firstRect(for: range).contains(point) {
                return attachment
            }
        }
        return nil
    }
}

/// Loads a held image when its placeholder is tapped (RichTextRemoteImages.onClick). The recognizer begins only
/// on a held image and recognizes alongside the text view's own gestures, so selection and links elsewhere are
/// untouched. Retained by the representable's coordinator.
@MainActor
final class RichTextHeldImageTap: NSObject, UIGestureRecognizerDelegate {
    private weak var textView: UITextView?
    var onTap: ((RichTextImageAttachment) -> Void)?

    init(textView: UITextView) {
        self.textView = textView
        super.init()
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        textView.addGestureRecognizer(recognizer)
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let textView, let onTap,
              let attachment = RichTextImageLoading.heldAttachment(at: recognizer.location(in: textView), in: textView) else {
            return
        }
        onTap(attachment)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let textView, onTap != nil else {
            return false
        }
        return RichTextImageLoading.heldAttachment(at: gestureRecognizer.location(in: textView), in: textView) != nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}

#endif
