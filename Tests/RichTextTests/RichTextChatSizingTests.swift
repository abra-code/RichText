// Regression tests for the content-hugging / first-layout sizing bug that showed up in a chat transcript
// (ActionUIChat: ScrollView { LazyVStack { bubble } }). RichText.sizeThatFits resolved an unspecified or
// infinite width proposal to the LIVE container's width, which is mutable probe state - 0 on the first
// layout pass, before the view has a frame. The ideal-size probe therefore reported a 0-width, one-line
// size. A LazyVStack caches the ideal it gets while lazily materializing a row, so bubbles rendered with
// the wrong geometry (text shifted / clipped, or - in a horizontally hugging bubble - collapsed to an empty
// pill) until a fresh layout was forced by scrolling the row off screen and back. The fix measures the
// natural text width for an unspecified / infinite proposal instead. These tests host the real view and
// assert it both draws and sizes to its content.

#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import RichText

final class RichTextChatSizingTests: XCTestCase {

    private let sample = "I don't have personal preferences or feelings, so I don't have a favorite color."

    /// Hosts `view` offscreen, runs the main loop so SwiftUI performs its sizing passes, then returns the
    /// hosted NSTextView (the one RichText builds) and the count of drawn (dark) pixels.
    @MainActor
    private func host<V: View>(_ view: V, window size: CGSize) -> (textView: NSTextView?, drawnPixels: Int) {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = hosting
        window.orderBack(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        hosting.layoutSubtreeIfNeeded()

        func find(_ v: NSView) -> NSTextView? {
            if let tv = v as? NSTextView { return tv }
            for sub in v.subviews { if let f = find(sub) { return f } }
            return nil
        }
        var drawn = 0
        if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                    if let px = rep.colorAt(x: x, y: y), px.alphaComponent > 0.05, px.brightnessComponent < 0.9 {
                        drawn += 1
                    }
                }
            }
        }
        return (find(hosting), drawn)
    }

    // A horizontally hugging bubble (fixedSize) proposes an unspecified width. It must hug to the text's
    // natural width and draw glyphs - not collapse to a near-zero-width empty pill. Both TextKit backends
    // share the width policy (richTextResolvedLayout), so both are exercised.
    @MainActor
    func testHorizontallyHuggingBubbleSizesToContentAndDraws() {
        for engine in [RichTextEngine.textKit1, .textKit2] {
            let windowWidth: CGFloat = 720
            let bubble = HStack {
                RichText(markdown: sample, engine: engine).fixedSize()
                Spacer(minLength: 0)
            }
            let (textView, drawn) = host(bubble, window: CGSize(width: windowWidth, height: 200))
            let width = textView?.frame.width ?? 0
            XCTAssertGreaterThan(drawn, 100, "\(engine): hugging bubble drew no glyphs - ideal-size probe collapsed the width")
            XCTAssertGreaterThan(width, 150, "\(engine): hugging bubble collapsed to a near-zero width (\(width))")
            XCTAssertLessThan(width, windowWidth - 50, "\(engine): hugging bubble did not hug - it filled the window (\(width))")
        }
    }

    // `.widthBehavior(.hug)` inside a `.frame(maxWidth:)` is the messaging-bubble idiom: a SHORT message must
    // hug its content (bubble narrower than the cap) rather than fill the column, while still drawing glyphs.
    // Both TextKit backends share the width policy, so both are exercised.
    @MainActor
    func testHugShortMessageHugsBelowTheCap() {
        let cap: CGFloat = 260
        let windowWidth: CGFloat = 720
        for engine in [RichTextEngine.textKit1, .textKit2] {
            let bubble = HStack {
                RichText(markdown: "hey", engine: engine)
                    .widthBehavior(.hug)
                    .frame(maxWidth: cap, alignment: .leading)
                Spacer(minLength: 0)
            }
            let (textView, drawn) = host(bubble, window: CGSize(width: windowWidth, height: 120))
            let width = textView?.frame.width ?? 0
            XCTAssertGreaterThan(drawn, 20, "\(engine): hugging bubble drew no glyphs")
            XCTAssertGreaterThan(width, 5, "\(engine): hugging bubble collapsed to zero width")
            XCTAssertLessThan(width, cap - 40, "\(engine): short message did not hug - it filled the cap (\(width))")
        }
    }

    // The same `.hug` bubble with a LONG message must NOT overflow the cap: it wraps at `maxWidth` (unlike
    // fixedSize hugging, which never wraps) and grows taller. Assert the width is clamped to the cap and the
    // wrapped height matches an independent measurement at the content width.
    @MainActor
    func testHugLongMessageWrapsAtTheCap() {
        let cap: CGFloat = 260
        let bubble = RichText(markdown: sample, engine: .textKit1)
            .widthBehavior(.hug)
            .frame(maxWidth: cap, alignment: .leading)
        let (textView, drawn) = host(bubble, window: CGSize(width: cap + 120, height: 300))
        let width = textView?.frame.width ?? 0

        let attributed = RichTextAttributedString.make(RichTextDocument(markdown: sample), engine: .textKit1)
        let storage = NSTextStorage(attributedString: attributed)
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let container = NSTextContainer(size: CGSize(width: cap, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        lm.addTextContainer(container)
        lm.ensureLayout(for: container)
        let expected = ceil(lm.usedRect(for: container).height)

        XCTAssertGreaterThan(drawn, 100, "long hugging bubble drew no glyphs")
        XCTAssertLessThanOrEqual(width, cap + 1, "long message overflowed the cap (\(width) > \(cap))")
        XCTAssertGreaterThan(expected, 30, "sample should wrap to multiple lines at this cap")
        XCTAssertEqual(textView?.frame.height ?? 0, expected, accuracy: 4,
                       "wrapped height mismatch - hug did not wrap at the cap")
    }

    // A full-width bubble (the chat transcript row) must get a height that matches the text wrapped at the
    // on-screen width. Before the fix, the ideal-size probe could report a one-line height that a LazyVStack
    // cached, clipping a multi-line message. Here the text wraps to multiple lines at the row width; assert
    // the hosted text view is tall enough for them.
    @MainActor
    func testFullWidthRowGetsWrappedHeight() {
        let rowWidth: CGFloat = 300   // narrow enough that `sample` wraps to several lines
        let row = VStack(alignment: .leading, spacing: 2) {
            RichText(markdown: sample, engine: .textKit1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
        .frame(width: rowWidth)

        let (textView, drawn) = host(row, window: CGSize(width: rowWidth + 40, height: 300))
        // Independent expectation: wrap `sample` at the content width and count line height.
        let attributed = RichTextAttributedString.make(RichTextDocument(markdown: sample), engine: .textKit1)
        let storage = NSTextStorage(attributedString: attributed)
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let container = NSTextContainer(size: CGSize(width: rowWidth - 20, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        lm.addTextContainer(container)
        lm.ensureLayout(for: container)
        let expected = ceil(lm.usedRect(for: container).height)

        XCTAssertGreaterThan(drawn, 100, "full-width row drew no glyphs")
        let actual = textView?.frame.height ?? 0
        XCTAssertGreaterThan(expected, 30, "sample should wrap to multiple lines at this width")
        XCTAssertEqual(actual, expected, accuracy: 4,
                       "row height \(actual) does not match the wrapped text height \(expected) - clipped / stale")
    }
}
#endif
