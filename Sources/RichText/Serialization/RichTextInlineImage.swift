// Sources/RichText/Serialization/RichTextInlineImage.swift
//
// The loaded-image values the serializers embed into copied HTML / RTF. Platform-independent (no rendering
// types), so the HTML serializer builds on every platform; the renderer of each platform produces them.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(CoreGraphics)
import CoreGraphics

/// A display size in points: CGSize on Apple platforms. Linux, which has no CoreGraphics, has its own struct
/// with the same `width` and `height`.
public typealias RichTextImageSize = CGSize
#else
/// A display size in points (CGSize on Apple platforms).
public struct RichTextImageSize: Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}
#endif

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
    public let displaySize: RichTextImageSize   // points, capped to the on-screen max width
    /// A still PNG frame for consumers that cannot carry `format` (RTF with a GIF): a static image beats
    /// none. nil when `format` is embeddable everywhere (PNG/JPEG).
    public let stillPNG: Data?

    public init(data: Data, format: RichTextImageFormat, displaySize: RichTextImageSize, stillPNG: Data? = nil) {
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
