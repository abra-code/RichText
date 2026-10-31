// Sources/RichText/Gtk/RichTextGtkClipboard.swift
//
// Puts a document on the clipboard in more than one form, so each paste target takes the richest it reads:
// HTML (with real tables, and loaded images embedded as data: URIs) and Markdown as the plain text. The Linux
// counterpart of RichTextPasteboard, the public hook for a "Copy as rich text" command; GTK programs take HTML,
// so there is no RTF here. (The text view's own selection copy stays plain text, as on Apple platforms, where
// it is the attributed text.)

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import AsyncImageCache
import CRichTextGtk

public enum RichTextGtkClipboard {

    /// The forms written, richest first: (MIME type, bytes).
    static func representations(of document: RichTextDocument) -> [(mimeType: String, bytes: [UInt8])] {
        let html = RichTextHTMLSerializer.document(from: document, images: cachedInlineImage)
        let markdown = RichTextMarkdownSerializer.string(from: document)
        return [
            ("text/html", Array(html.utf8)),
            ("text/plain;charset=utf-8", Array(markdown.utf8)),
            ("text/plain", Array(markdown.utf8)),
        ]
    }

    /// Replaces the clipboard's contents (the default display's, unless one is given) with `document` as HTML
    /// and Markdown.
    @MainActor
    public static func write(_ document: RichTextDocument, clipboard: OpaquePointer? = nil) {
        guard let target = clipboard ?? gdk_display_get_default().flatMap({ gdk_display_get_clipboard($0) }) else {
            return
        }
        var providers: [UnsafeMutablePointer<GdkContentProvider>?] = representations(of: document).map { form in
            let bytes = form.bytes.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }
            defer {
                g_bytes_unref(bytes)
            }
            return gdk_content_provider_new_for_bytes(form.mimeType, bytes)
        }
        // The union takes the providers it is given.
        let union = providers.withUnsafeMutableBufferPointer { gdk_content_provider_new_union($0.baseAddress, gsize($0.count)) }
        gdk_clipboard_set_content(target, union)
        g_object_unref(UnsafeMutableRawPointer(union))
    }

    // A loaded image's original bytes, for embedding: PNG, JPEG and GIF as they are (the formats HTML targets
    // read everywhere), at its display size (the natural size up to the renderer's width cap). Anything else,
    // or an image not loaded, keeps its URL.
    static func cachedInlineImage(_ urlString: String) -> RichTextInlineImage? {
        guard let url = URL(string: urlString), RichTextURLPolicy.allowsImage(url),
              let original = ImageStore.shared.cachedOriginalBytes(for: url),
              let format = imageFormat(original.data) else {
            return nil
        }
        let width = Double(original.pixelSize.width)
        let height = Double(original.pixelSize.height)
        let cap = RichTextGtkImageSlot.maxWidth
        let scale = width > cap ? cap / width : 1
        return RichTextInlineImage(data: original.data, format: format,
                                   displaySize: RichTextImageSize(width: width * scale, height: (height * scale).rounded()))
    }

    // The format by the bytes' signature.
    static func imageFormat(_ data: Data) -> RichTextImageFormat? {
        let head = Array(data.prefix(4))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return .png
        }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) {
            return .jpeg
        }
        if head.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            return .gif
        }
        return nil
    }
}
