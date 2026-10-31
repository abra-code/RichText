// Tests/RichTextTests/Gtk/RichTextGtkClipboardTests.swift
//
// Copy as rich text on Linux: the HTML and Markdown forms, loaded images embedded, and (with a display) the
// clipboard offering them.

import XCTest
import Foundation
import AsyncImageCache
import CRichTextGtk
@testable import RichText

@MainActor
final class RichTextGtkClipboardTests: XCTestCase {

    func testFormsAreHTMLThenMarkdown() throws {
        let document = RichTextDocument(markdown: "# T\n\n| a | b |\n|---|---|\n| 1 | 2 |")
        let forms = RichTextGtkClipboard.representations(of: document)
        XCTAssertEqual(forms.map(\.mimeType), ["text/html", "text/plain;charset=utf-8", "text/plain"])
        let html = String(decoding: forms[0].bytes, as: UTF8.self)
        XCTAssertTrue(html.contains("<table"), html)
        XCTAssertEqual(String(decoding: forms[1].bytes, as: UTF8.self), RichTextMarkdownSerializer.string(from: document))
    }

    func testLoadedImageIsEmbeddedAndOthersKeepTheirURL() throws {
        let png = try pngData(width: 4, height: 4)
        // A generic media type, so the embedded src (typed by the bytes' signature) differs from the URL kept
        // for an image not embedded: with image/png both would read the same.
        let dataURL = "data:application/octet-stream;base64," + png.base64EncodedString()
        try load(dataURL)
        let embedded = try XCTUnwrap(RichTextGtkClipboard.cachedInlineImage(dataURL))
        XCTAssertEqual(embedded.format, .png)
        XCTAssertEqual(embedded.data, png)
        XCTAssertEqual(embedded.displaySize, RichTextImageSize(width: 4, height: 4))
        let document = RichTextDocument(markdown: "![dot](\(dataURL)) ![far](https://x.test/far.png)")
        let html = String(decoding: RichTextGtkClipboard.representations(of: document)[0].bytes, as: UTF8.self)
        XCTAssertTrue(html.contains("src=\"data:image/png;base64," + png.base64EncodedString() + "\""), "the loaded image is embedded")
        XCTAssertFalse(html.contains("application/octet-stream"), "the loaded image's URL is not kept")
        XCTAssertTrue(html.contains("src=\"https://x.test/far.png\""), "an image not loaded keeps its URL")
    }

    func testEmbeddedDisplaySizeIsCappedAtTheRendererWidth() throws {
        let dataURL = "data:image/png;base64," + (try pngData(width: 640, height: 21)).base64EncodedString()
        try load(dataURL)
        let embedded = try XCTUnwrap(RichTextGtkClipboard.cachedInlineImage(dataURL))
        XCTAssertEqual(embedded.displaySize, RichTextImageSize(width: 320, height: 11))
    }

    func testImageFormatBySignature() {
        XCTAssertEqual(RichTextGtkClipboard.imageFormat(Data([0x89, 0x50, 0x4E, 0x47, 0x0D])), .png)
        XCTAssertEqual(RichTextGtkClipboard.imageFormat(Data([0xFF, 0xD8, 0xFF, 0xE0])), .jpeg)
        XCTAssertEqual(RichTextGtkClipboard.imageFormat(Data("GIF89a".utf8)), .gif)
        XCTAssertNil(RichTextGtkClipboard.imageFormat(Data("RIFF".utf8)))
        XCTAssertNil(RichTextGtkClipboard.imageFormat(Data()))
    }

    func testClipboardOffersBothForms() throws {
        try XCTSkipUnless(gtkDisplay(), "no display")
        RichTextGtkClipboard.write(RichTextDocument(markdown: "**x**"))
        let clipboard = try XCTUnwrap(gdk_display_get_clipboard(gdk_display_get_default()))
        let formats = try XCTUnwrap(gdk_clipboard_get_formats(clipboard))
        XCTAssertNotEqual(gdk_content_formats_contain_mime_type(formats, "text/html"), 0)
        XCTAssertNotEqual(gdk_content_formats_contain_mime_type(formats, "text/plain"), 0)
    }

    func testClipboardServesTheMarkdownAsText() throws {
        try XCTSkipUnless(gtkDisplay(), "no display")
        let document = RichTextDocument(markdown: "**x** caf\u{E9}")
        RichTextGtkClipboard.write(document)
        let clipboard = try XCTUnwrap(gdk_display_get_clipboard(gdk_display_get_default()))
        final class Reply {
            var done = false
            var text: String?
        }
        let reply = Reply()
        let finished: GAsyncReadyCallback = { source, result, data in
            let reply = Unmanaged<Reply>.fromOpaque(data!).takeRetainedValue()
            if let text = gdk_clipboard_read_text_finish(OpaquePointer(source), result, nil) {
                reply.text = String(cString: text)
                g_free(text)
            }
            reply.done = true
        }
        gdk_clipboard_read_text_async(clipboard, nil, finished, Unmanaged.passRetained(reply).toOpaque())
        let end = g_get_monotonic_time() + 5_000_000
        while !reply.done, g_get_monotonic_time() < end {
            if g_main_context_iteration(nil, 0) == 0 {
                usleep(1000)
            }
        }
        XCTAssertEqual(reply.text, RichTextMarkdownSerializer.string(from: document))
    }

    // Loads `urlString` into the shared image store, pumping the main context until it finishes.
    private func load(_ urlString: String) throws {
        var done = false
        ImageStore.shared.load(ImageRequest(url: try XCTUnwrap(URL(string: urlString)), targetWidth: 320)) { _ in done = true }
        let end = g_get_monotonic_time() + 5_000_000
        while !done, g_get_monotonic_time() < end {
            if g_main_context_iteration(nil, 0) == 0 {
                usleep(1000)
            }
        }
        XCTAssertTrue(done)
    }

    private func pngData(width: Int32, height: Int32) throws -> Data {
        let pixbuf = try XCTUnwrap(gdk_pixbuf_new(GDK_COLORSPACE_RGB, 1, 8, width, height))
        defer {
            g_object_unref(UnsafeMutableRawPointer(pixbuf))
        }
        gdk_pixbuf_fill(pixbuf, 0x3366CCFF)
        var buffer: UnsafeMutablePointer<gchar>?
        var size: gsize = 0
        _ = gdk_pixbuf_save_to_bufferv(pixbuf, &buffer, &size, "png", nil, nil, nil)
        let start = try XCTUnwrap(buffer)
        defer {
            g_free(start)
        }
        return Data(bytes: start, count: Int(size))
    }
}
