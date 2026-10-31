// Sources/RichText/Rendering/RichTextImagePlaceholder.swift
//
// What an image's placeholder says before its pixels show, the same on every renderer: the alt text while
// loading or after a failure, and for a remote image held by RichTextRemoteImages, the alt text over a line
// naming the host a click would contact.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
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

enum RichTextImagePlaceholder {
    /// The placeholder's text. `action` is the verb of the click that loads a held image ("Click", "Tap").
    static func label(alt: String, url: URL?, failed: Bool, hold: RichTextImageHold, action: String) -> String {
        // The host as written, percent escapes kept: a decoded host could show an escaped "/" or line break
        // and pass one domain off as another.
        let host = url?.host(percentEncoded: true) ?? "the web"
        switch hold {
        case .awaitingClick:
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
}
