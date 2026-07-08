// Regression tests for RichTextTopAlignedTextView, the macOS text view used by the TextKit 1 RichText path.
// It keeps glyphs pinned to the top of the view: TextKit 1 can intermittently lay the first line fragment
// out below y = 0 (usedRect.minY > 0), which drew the text low inside a chat bubble and stuck there until the
// row was re-created. The view subtracts that offset from textContainerOrigin so the text always draws from
// the top. Here an exclusion path forces a deterministic top offset to exercise the compensation (the live
// bug's transient stale-layout offset is not reproducible headless, but the fix is source-agnostic).

#if os(macOS)
import XCTest
import AppKit
@testable import RichText

final class RichTextTopAlignTests: XCTestCase {

    @MainActor
    private func makeTextView(topExclusion: CGFloat) -> RichTextTopAlignedTextView {
        let storage = NSTextStorage(attributedString: NSAttributedString(
            string: "First line of text.\nSecond line of text.",
            attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        let layoutManager = RichTextLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        if topExclusion > 0 {
            container.exclusionPaths = [NSBezierPath(rect: CGRect(x: 0, y: 0, width: 300, height: topExclusion))]
        }
        layoutManager.addTextContainer(container)
        let textView = RichTextTopAlignedTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 200),
                                                  textContainer: container)
        textView.textContainerInset = .zero
        layoutManager.ensureLayout(for: container)
        return textView
    }

    // No layout offset (the normal case): the override is a no-op, origin stays at the inset.
    @MainActor
    func testNoOffsetLeavesOriginAtInset() {
        let tv = makeTextView(topExclusion: 0)
        let used = tv.layoutManager!.usedRect(for: tv.textContainer!)
        XCTAssertEqual(used.minY, 0, accuracy: 0.5, "sanity: normal layout starts at y = 0")
        XCTAssertEqual(tv.textContainerOrigin.y, tv.textContainerInset.height, accuracy: 0.5,
                       "with no top offset the origin must equal the inset (no shift)")
    }

    // A forced top offset (usedRect.minY > 0) must be cancelled: origin pulled up by exactly that offset, so
    // the first glyph draws at the top of the view.
    @MainActor
    func testTopOffsetIsCompensated() {
        let tv = makeTextView(topExclusion: 40)
        let minY = tv.layoutManager!.usedRect(for: tv.textContainer!).minY
        XCTAssertGreaterThan(minY, 1, "sanity: the exclusion path should push the first line down")
        XCTAssertEqual(tv.textContainerOrigin.y, tv.textContainerInset.height - minY, accuracy: 0.5,
                       "origin must be pulled up by the layout's top offset")
        // Net effect: first glyph renders at the top of the view (origin.y + minY == inset.height).
        XCTAssertEqual(tv.textContainerOrigin.y + minY, tv.textContainerInset.height, accuracy: 0.5,
                       "compensation must place the first line at the top of the view")
    }

    // TextKit 2 parity (SelectableTextView): the override reads the offset from the first layout FRAGMENT
    // (TK2 has no NSLayoutManager usedRect). TK2 ignores container exclusionPaths, so a top offset can't be
    // forced headlessly - the compensation itself is verified in the demo app; here we exercise the
    // textLayoutManager branch and assert normal content is not shifted (offset == 0 -> origin at the inset).
    @MainActor
    func testTK2NoOffsetLeavesOriginAtInset() {
        let tv = SelectableTextView(usingTextLayoutManager: true)
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        tv.textStorage?.setAttributedString(NSAttributedString(
            string: "First line of text.\nSecond line of text.",
            attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        var firstMinY: CGFloat = -1
        tv.textLayoutManager?.enumerateTextLayoutFragments(from: tv.textLayoutManager!.documentRange.location,
                                                           options: [.ensuresLayout]) { f in
            firstMinY = f.layoutFragmentFrame.minY
            return false
        }
        XCTAssertEqual(firstMinY, 0, accuracy: 0.5, "sanity: normal TK2 layout starts at y = 0")
        XCTAssertEqual(tv.textContainerOrigin.y, tv.textContainerInset.height, accuracy: 0.5,
                       "TK2: with no top offset the origin must equal the inset (no shift)")
    }
}
#endif
