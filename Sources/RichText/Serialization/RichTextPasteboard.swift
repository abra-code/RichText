// Sources/RichText/Serialization/RichTextPasteboard.swift
//
// Writes a document to the system pasteboard in MULTIPLE representations (RTF with real tables, HTML,
// and Markdown/plain) so each paste target picks the richest it supports - the way Notes interoperates.
// This is the public hook for a "Copy as rich text" command. (Wiring it into the text view's default
// selection-copy - which needs selection -> model mapping - is a documented refinement; today the
// default copy uses the attributed string, where a table copies as tab-separated text.)

import Foundation

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#endif

public enum RichTextPasteboard {

    /// Replaces the general pasteboard contents with RTF + HTML + Markdown representations of `document`.
    public static func write(_ document: RichTextDocument) {
        // Embed already-loaded images (from the shared cache) so pictures survive paste into rich editors;
        // images not yet loaded fall back to their URL / alt text.
        let images: RichTextImageResolver = { urlString in
            URL(string: urlString).flatMap { RichTextImageLoading.cachedInlineImage(for: $0) }
        }
        let rtf = RichTextRTFSerializer.data(from: document, images: images)
        let html = RichTextHTMLSerializer.document(from: document, images: images)
        let markdown = RichTextMarkdownSerializer.string(from: document)

        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(rtf, forType: .rtf)
        pasteboard.setString(html, forType: .html)
        pasteboard.setString(markdown, forType: .string)
        #elseif canImport(UIKit)
        var item: [String: Any] = [
            UTType.rtf.identifier: rtf,
            UTType.html.identifier: html,
            UTType.utf8PlainText.identifier: markdown,
        ]
        // Plain-text convenience for targets that only read .text.
        item[UTType.text.identifier] = markdown
        UIPasteboard.general.items = [item]
        #endif
    }
}
