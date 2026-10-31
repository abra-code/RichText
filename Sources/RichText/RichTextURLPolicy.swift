// Sources/RichText/RichTextURLPolicy.swift
//
// URL allow-lists applied at the RENDER / SERIALIZE / IMAGE-LOAD boundaries. The document model keeps the
// RAW url strings from (untrusted, streamed) Markdown losslessly; policy is enforced only where a url would
// otherwise become something dangerous: a tappable on-screen link, an href/HYPERLINK in copied HTML/RTF, or
// an image load. The threat for links is `javascript:` (script execution from a tapped link or from pasted
// HTML). Images load from the web (governed by RichTextRemoteImages, since a fetch tells the image's host the
// document was shown), from `data:` bytes in the document, and from local `file:` URLs: a local picture is
// shown to the user who can already see it and sends nothing anywhere. Only explicit, absolute, allow-listed
// schemes pass; scheme-less/relative strings are rejected here (we never guess a base - a caller that knows
// the document's location resolves them first with RichTextDocument.resolvingImageURLs(against:)).

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// When a document's REMOTE images (http / https) are fetched. Fetching is itself a disclosure: the request
/// tells the image's host that this document was rendered, from which address, and anything the URL carries
/// - so Markdown written by an untrusted party (a model, an agent, a web page) can use an image to send data
/// wherever it likes the moment it is shown. `data:` images carry their bytes inline and local `file:` images
/// send nothing, so both are always shown. An image already in the process-wide cache is shown in every mode,
/// since showing cached bytes sends nothing.
public enum RichTextRemoteImages: String, Sendable, Hashable, CaseIterable {
    /// Fetched as soon as the document renders: the default, and the behavior before this option existed.
    case automatic
    /// A placeholder naming the image's host until the user clicks (taps) it; then that one image is fetched.
    case onClick
    /// Never fetched; the placeholder says so.
    case never
}

public enum RichTextURLPolicy {

    // Hyperlink targets: navigation-only schemes. `javascript:`, `data:`, `file:`, and anything unknown are
    // rejected so they can never be made tappable or written as an href/HYPERLINK. `static let` so the
    // allow-list is one auditable place. (tel is included: harmless dialer intent.)
    public static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto", "tel"]

    // Image sources: remote schemes, `data:` (bytes already inline in the Markdown) and local `file:` images.
    public static let allowedImageSchemes: Set<String> = ["http", "https", "data", "file"]

    /// The URL for a hyperlink target, or nil if its scheme is not allow-listed. A relative/scheme-less
    /// string is rejected (a link must carry an explicit, absolute, allow-listed scheme). Scheme comparison
    /// is case-insensitive (URL schemes are case-insensitive per RFC 3986, and `javaScript:` is a real bypass).
    public static func allowedLink(_ string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              allowedLinkSchemes.contains(scheme) else {
            return nil
        }
        return url
    }

    /// Whether an image URL may be loaded AND embedded. True only for an allow-listed scheme
    /// (http/https/data/file); false for javascript:, other schemes, and scheme-less/relative URLs.
    public static func allowsImage(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }
        return allowedImageSchemes.contains(scheme)
    }

    /// Whether loading an image URL means a fetch from somewhere else (today http / https), which
    /// `RichTextRemoteImages` governs: every allowed scheme except `data:`, whose bytes are already in the
    /// document, and `file:`, which is read locally. Defined by exclusion, so a scheme added to
    /// `allowedImageSchemes` later is held by default.
    public static func isRemoteImage(_ url: URL) -> Bool {
        guard allowsImage(url), let scheme = url.scheme?.lowercased() else {
            return false
        }
        return scheme != "data" && scheme != "file"
    }
}
