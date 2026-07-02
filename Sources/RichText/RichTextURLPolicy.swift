// Sources/RichText/RichTextURLPolicy.swift
//
// URL allow-lists applied at the RENDER / SERIALIZE / IMAGE-LOAD boundaries. The document model keeps the
// RAW url strings from (untrusted, streamed) Markdown losslessly; policy is enforced only where a url would
// otherwise become something dangerous: a tappable on-screen link, an href/HYPERLINK in copied HTML/RTF, or
// an actual disk/network fetch. The threats are `javascript:` (script execution from a tapped link or from
// pasted HTML) and `file:` (reading a local file off disk - and then exfiltrating it, since a file: image
// would be cached and embedded as a data: URI when the user copies the document). Only explicit, absolute,
// allow-listed schemes pass; scheme-less/relative strings are rejected (we never guess a base).

import Foundation

public enum RichTextURLPolicy {

    // Hyperlink targets: navigation-only schemes. `javascript:`, `data:`, `file:`, and anything unknown are
    // rejected so they can never be made tappable or written as an href/HYPERLINK. `static let` so the
    // allow-list is one auditable place. (tel is included: harmless dialer intent.)
    public static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto", "tel"]

    // Image sources: remote schemes plus `data:` (bytes already inline in the Markdown). `file:` is
    // deliberately EXCLUDED - an untrusted file: image must never be read from disk.
    public static let allowedImageSchemes: Set<String> = ["http", "https", "data"]

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

    /// Whether an image URL may be fetched AND embedded. True only for an allow-listed scheme
    /// (http/https/data); false for file:, javascript:, and scheme-less/relative URLs.
    public static func allowsImage(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }
        return allowedImageSchemes.contains(scheme)
    }
}
