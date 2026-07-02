// Regression tests for the SwiftUI sizeThatFits / live-text-container interaction (macOS harness).
//
// SwiftUI probes a representable's sizeThatFits at several widths in one layout pass (the real width,
// then 0, then nil). RichText's sizeThatFits measures by resizing the LIVE NSTextContainer, and
// widthTracksTextView only re-tracks the container on an actual frame CHANGE - so when the final probe
// was width 0 and the view's frame was already final (heights equal at every probe width, e.g. short
// unwrapped RTF paragraphs), the view drew with a width-0 container: no glyphs at all. Markdown-built
// documents masked the bug because their wrapped heights differ across probe widths, forcing a real
// frame change that re-tracked the container. The fix restores the on-screen width after measuring;
// these tests host the real view in an offscreen NSHostingView and assert that glyphs actually draw.

#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import RichText

final class RichTextSwiftUISizingTests: XCTestCase {

    // Short unwrapped paragraphs: identical measured height at every probe width, which is exactly the
    // shape that used to leave the container at the width-0 probe. Raw importer output on purpose - runs
    // carry only a font attribute (no foreground color / paragraph style), like real RTF decoding.
    private let sampleRTF = #"""
    {\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\fswiss Helvetica;}}
    \f0\fs36\b RTF heading\b0\fs24\par
    A paragraph with \b bold\b0 , \i italic\i0 , and plain text.\par
    A second paragraph.\par}
    """#

    private func decodedRTF() throws -> NSAttributedString {
        let data = try XCTUnwrap(sampleRTF.data(using: .utf8))
        return try NSAttributedString(data: data,
                                      options: [.documentType: NSAttributedString.DocumentType.rtf],
                                      documentAttributes: nil)
    }

    /// Hosts `view` in an offscreen window, runs the main loop so SwiftUI performs its sizing passes,
    /// then renders the hierarchy and counts dark pixels (glyph coverage).
    @MainActor
    private func drawnGlyphPixels<V: View>(hosting view: V) -> Int {
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
                if let px = rep.colorAt(x: x, y: y), px.alphaComponent > 0.05, px.brightnessComponent < 0.9 {
                    drawn += 1
                }
            }
        }
        return drawn
    }

    @MainActor
    func testAttributedRTFDrawsOnFirstAppearanceTextKit1() throws {
        let drawn = drawnGlyphPixels(hosting: RichText(attributed: try decodedRTF(), engine: .textKit1))
        XCTAssertGreaterThan(drawn, 100, "TK1 RTF view drew no glyphs - live container left at a probe width?")
    }

    @MainActor
    func testAttributedRTFDrawsOnFirstAppearanceTextKit2() throws {
        let drawn = drawnGlyphPixels(hosting: RichText(attributed: try decodedRTF(), engine: .textKit2))
        XCTAssertGreaterThan(drawn, 100, "TK2 RTF view drew no glyphs - live container left at a probe width?")
    }
}
#endif
