// Engine-feature tests for the RichText(attributed:) path (macOS harness).
//
// RichText(attributed:) hands the decoded NSAttributedString to a real TextKit stack, so it renders
// features SwiftUI's Text view drops: NSTextTable, NSTextList, text attachments, paragraph styling,
// underline variants, shadows, kerning, superscript. These tests pin that capability down two ways:
//
//   1. Round-trip: build each feature programmatically with AppKit, serialize to RTF with Cocoa's own
//      writer, decode it back, and assert the attribute survives - proving a bundled .rtf file (like the
//      demo's TypographyTour.rtf, generated the same way) carries the feature into RichText.
//   2. Render: host the real RichText view offscreen (the NSHostingView + pixel-count harness from
//      RichTextSwiftUISizingTests) and assert both engines actually draw the content. TextKit 1 lays out
//      NSTextTable natively; a TextKit 2 NSTextView has no table layout and silently DOWNGRADES itself to
//      TextKit 1 for such content (textLayoutManager goes nil) - both paths must draw, never blank or crash.

#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import RichText

final class RichTextAttributedFeatureTests: XCTestCase {

    // MARK: - Round-trip helpers

    /// Serializes to RTF with Cocoa's writer and decodes back - the exact path a bundled .rtf file travels.
    private func rtfRoundTrip(_ attributed: NSAttributedString) throws -> NSAttributedString {
        let data = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                       documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        return try NSAttributedString(data: data,
                                      options: [.documentType: NSAttributedString.DocumentType.rtf],
                                      documentAttributes: nil)
    }

    private func firstAttribute<T>(_ key: NSAttributedString.Key, in attributed: NSAttributedString, as type: T.Type) -> T? {
        var found: T?
        attributed.enumerateAttribute(key, in: NSRange(location: 0, length: attributed.length)) { value, _, stop in
            if let value = value as? T {
                found = value
                stop.pointee = true
            }
        }
        return found
    }

    /// A 2x2 NSTextTable document: header row with background + borders, one body row, trailing paragraph.
    private func tableDocument() -> NSAttributedString {
        let doc = NSMutableAttributedString()
        let table = NSTextTable()
        table.numberOfColumns = 2
        let cells = [("Feature", "Engine"), ("Tables", "TextKit 1")]
        for (row, pair) in cells.enumerated() {
            for (col, text) in [pair.0, pair.1].enumerated() {
                let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1,
                                             startingColumn: col, columnSpan: 1)
                block.setBorderColor(.gray)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(4, type: .absoluteValueType, for: .padding)
                if row == 0 { block.backgroundColor = .lightGray }
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                doc.append(NSAttributedString(string: text + "\n",
                                              attributes: [.font: NSFont.systemFont(ofSize: 12),
                                                           .paragraphStyle: style]))
            }
        }
        doc.append(NSAttributedString(string: "After the table.\n",
                                      attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        return doc
    }

    // MARK: - Render harness (see RichTextSwiftUISizingTests for the original)

    /// Hosts `view` in an offscreen window, runs the main loop so SwiftUI performs its sizing passes,
    /// then renders the hierarchy and counts pixels matching `predicate`.
    @MainActor
    private func drawnPixels<V: View>(hosting view: V,
                                      where predicate: (NSColor) -> Bool = { $0.brightnessComponent < 0.9 }) -> Int {
        let hosting = NSHostingView(rootView:
            ScrollView {
                view
                    .padding()
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
            }
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = hosting
        window.orderBack(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))

        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            XCTFail("no bitmap rep for \(hosting.bounds)")
            return 0
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        var drawn = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                if let px = rep.colorAt(x: x, y: y), px.alphaComponent > 0.05, predicate(px) {
                    drawn += 1
                }
            }
        }
        return drawn
    }

    // MARK: - NSTextTable

    func testTableSurvivesRTFRoundTrip() throws {
        let decoded = try rtfRoundTrip(tableDocument())
        let style = firstAttribute(.paragraphStyle, in: decoded, as: NSParagraphStyle.self)
        XCTAssertEqual(style?.textBlocks.isEmpty, false, "NSTextTable did not survive the RTF round-trip")
    }

    @MainActor
    func testTableRendersInBothEngines() throws {
        let decoded = try rtfRoundTrip(tableDocument())
        let tk1 = drawnPixels(hosting: RichText(attributed: decoded, engine: .textKit1))
        XCTAssertGreaterThan(tk1, 100, "TK1 drew no glyphs for an NSTextTable document")
        // A TextKit 2 NSTextView downgrades itself to TextKit 1 for table content; the view must keep
        // drawing (and sizeThatFits must keep measuring, via the TK1 stack) - never blank, never crash.
        let tk2 = drawnPixels(hosting: RichText(attributed: decoded, engine: .textKit2))
        XCTAssertGreaterThan(tk2, 100, "TK2 drew no glyphs for an NSTextTable document")
    }

    // MARK: - NSTextList

    @MainActor
    func testTextListSurvivesRTFRoundTrip() throws {
        let doc = NSMutableAttributedString()
        let list = NSTextList(markerFormat: .disc, options: 0)
        for item in ["first", "second"] {
            let style = NSMutableParagraphStyle()
            style.textLists = [list]
            style.headIndent = 36
            // No leading tab before the marker: Cocoa's RTF writer folds a "\t<marker>\t" prefix into
            // \listtext, which the importer then CONSUMES - the visible marker would vanish for a
            // read-only view (TextKit 1 draws no marker of its own; the glyphs must be in the string).
            doc.append(NSAttributedString(string: "\u{2022}\t" + item + "\n",
                                          attributes: [.font: NSFont.systemFont(ofSize: 12),
                                                       .paragraphStyle: style]))
        }
        let decoded = try rtfRoundTrip(doc)
        var found = false
        decoded.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: decoded.length)) { value, _, _ in
            if let style = value as? NSParagraphStyle, !style.textLists.isEmpty { found = true }
        }
        XCTAssertTrue(found, "NSTextList did not survive the RTF round-trip")
        XCTAssertTrue(decoded.string.contains("\u{2022}"), "the visible list marker was consumed by the round-trip")

        let tk1 = drawnPixels(hosting: RichText(attributed: decoded, engine: .textKit1))
        XCTAssertGreaterThan(tk1, 50, "TK1 drew no glyphs for an NSTextList document")
        let tk2 = drawnPixels(hosting: RichText(attributed: decoded, engine: .textKit2))
        XCTAssertGreaterThan(tk2, 50, "TK2 drew no glyphs for an NSTextList document")
    }

    // MARK: - Typography attributes

    func testTypographyAttributesSurviveRTFRoundTrip() throws {
        let doc = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13)]
        func run(_ text: String, _ extra: [NSAttributedString.Key: Any]) {
            doc.append(NSAttributedString(string: text, attributes: base.merging(extra) { _, new in new }))
        }
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 1, height: -1)
        shadow.shadowBlurRadius = 2
        run("shadow ", [.shadow: shadow])
        run("double-underline ", [.underlineStyle: NSUnderlineStyle.double.rawValue])
        run("kerned ", [.kern: 2.5])
        run("super", [.superscript: 1])
        run("highlight ", [.backgroundColor: NSColor.yellow])
        run("outline ", [.strokeWidth: 3.0])
        run("struck\n", [.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                         .strikethroughColor: NSColor.red])

        let decoded = try rtfRoundTrip(doc)
        XCTAssertNotNil(firstAttribute(.shadow, in: decoded, as: NSShadow.self), "shadow lost")
        let underline = firstAttribute(.underlineStyle, in: decoded, as: NSNumber.self)
        XCTAssertEqual(underline.map { $0.intValue & NSUnderlineStyle.double.rawValue }, NSUnderlineStyle.double.rawValue, "double underline lost")
        let kern = firstAttribute(.kern, in: decoded, as: NSNumber.self)
        XCTAssertEqual(kern?.doubleValue ?? 0, 2.5, accuracy: 0.01, "kerning lost")
        XCTAssertNotEqual(firstAttribute(.superscript, in: decoded, as: NSNumber.self)?.intValue ?? 0, 0, "superscript lost")
        XCTAssertNotNil(firstAttribute(.backgroundColor, in: decoded, as: NSColor.self), "background highlight lost")
        XCTAssertGreaterThan(firstAttribute(.strokeWidth, in: decoded, as: NSNumber.self)?.doubleValue ?? 0, 0, "stroke outline lost")
        XCTAssertNotNil(firstAttribute(.strikethroughColor, in: decoded, as: NSColor.self), "strikethrough color lost")
    }

    // MARK: - Attachments

    /// An attachment image drawn in a color no text uses proves the ATTACHMENT rendered, not just glyphs.
    @MainActor
    func testAttachmentImageRendersInBothEngines() throws {
        let size = NSSize(width: 60, height: 40)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()

        let doc = NSMutableAttributedString(string: "Before the image ",
                                            attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(origin: .zero, size: size)
        doc.append(NSAttributedString(attachment: attachment))
        doc.append(NSAttributedString(string: " and after.\n", attributes: [.font: NSFont.systemFont(ofSize: 13)]))

        func isRed(_ color: NSColor) -> Bool {
            guard let rgb = color.usingColorSpace(.sRGB) else { return false }
            return rgb.redComponent > 0.6 && rgb.greenComponent < 0.4 && rgb.blueComponent < 0.4
        }
        let tk1 = drawnPixels(hosting: RichText(attributed: doc, engine: .textKit1), where: isRed)
        XCTAssertGreaterThan(tk1, 50, "TK1 did not draw the attachment image")
        let tk2 = drawnPixels(hosting: RichText(attributed: doc, engine: .textKit2), where: isRed)
        XCTAssertGreaterThan(tk2, 50, "TK2 did not draw the attachment image")
    }

    // MARK: - HTML importer

    /// The demo's Showcase.html path: WebKit's importer turns <table> into a real NSTextTable and a
    /// data:-URI <img> into a ready-to-render NSTextAttachment. (Main-thread work, like the demo.)
    @MainActor
    func testHTMLImporterProducesTableAndRenders() throws {
        let html = """
        <table border="1"><tr><th>H1</th><th>H2</th></tr><tr><td>a</td><td>b</td></tr></table>
        <p style="text-align: center;">centered</p>
        """
        let data = try XCTUnwrap(html.data(using: .utf8))
        let decoded = try NSAttributedString(data: data,
                                             options: [.documentType: NSAttributedString.DocumentType.html,
                                                       .characterEncoding: String.Encoding.utf8.rawValue],
                                             documentAttributes: nil)
        var foundTable = false, foundCenter = false
        decoded.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: decoded.length)) { value, _, _ in
            guard let style = value as? NSParagraphStyle else { return }
            if !style.textBlocks.isEmpty { foundTable = true }
            if style.alignment == .center { foundCenter = true }
        }
        XCTAssertTrue(foundTable, "HTML importer produced no NSTextTable")
        XCTAssertTrue(foundCenter, "HTML importer lost text-align: center")

        let tk1 = drawnPixels(hosting: RichText(attributed: decoded, engine: .textKit1))
        XCTAssertGreaterThan(tk1, 50, "TK1 drew no glyphs for the HTML table document")
        let tk2 = drawnPixels(hosting: RichText(attributed: decoded, engine: .textKit2))
        XCTAssertGreaterThan(tk2, 50, "TK2 drew no glyphs for the HTML table document")
    }
}
#endif
