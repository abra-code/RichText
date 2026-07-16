// Tests for RichTextDiagnostics, the geometry recorder / anomaly detector behind the intermittent
// "text draws shifted down / outside its bubble" investigation (macOS). The live bug has never
// reproduced headless, so these tests pin the DETECTOR's behavior instead: a healthy laid-out view
// reports no anomalies (so the always-on check stays silent in production), and each class of
// injected geometry corruption is flagged with the expected key (so a field dump names the culprit).

#if os(macOS)
import XCTest
import AppKit
@testable import RichText

final class RichTextDiagnosticsTests: XCTestCase {

    @MainActor
    private func makeLaidOutTextView() -> RichTextTopAlignedTextView {
        let storage = NSTextStorage(attributedString: NSAttributedString(
            string: "First line of text.\nSecond line of text.",
            attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        let layoutManager = RichTextLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let textView = RichTextTopAlignedTextView(frame: .zero, textContainer: container)
        textView.textContainerInset = .zero
        layoutManager.ensureLayout(for: container)
        // Adopt the laid-out size, the way SwiftUI would after sizeThatFits.
        let used = layoutManager.usedRect(for: container)
        textView.setFrameSize(NSSize(width: 300, height: ceil(used.height)))
        return textView
    }

    // A healthy view - laid out, frame matching the content - must report NO anomalies, or the
    // always-on draw check would spam logs (and cry wolf) in production. Layer-backed like the real
    // SwiftUI hosting, so the layer checks (frame sync, transforms, contentsRect) run against a live
    // CALayer's defaults.
    @MainActor
    func testHealthyViewReportsNoAnomalies() {
        let tv = makeLaidOutTextView()
        tv.wantsLayer = true
        XCTAssertNotNil(tv.layer, "sanity: the layer checks should actually run")
        tv.diag.noteFit(tv, proposalWidth: 300, result: tv.frame.size)
        let anomalies = tv.diag.collectAnomalies(tv)
        XCTAssertTrue(anomalies.isEmpty, "unexpected anomalies: \(anomalies.map(\.detail))")
    }

    // The TextKit 2 twin: a healthy, layer-backed SelectableTextView sized to its content must also
    // report no anomalies (exercises the TK2 fragment branch and the layer defaults).
    @MainActor
    func testHealthyTK2ViewReportsNoAnomalies() {
        let tv = SelectableTextView(usingTextLayoutManager: true)
        tv.wantsLayer = true
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.size = CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
        tv.textStorage?.setAttributedString(NSAttributedString(
            string: "First line of text.\nSecond line of text.",
            attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        var maxY: CGFloat = 0
        tv.textLayoutManager?.enumerateTextLayoutFragments(from: tv.textLayoutManager!.documentRange.location,
                                                           options: [.ensuresLayout]) { fragment in
            maxY = max(maxY, fragment.layoutFragmentFrame.maxY)
            return true
        }
        XCTAssertGreaterThan(maxY, 0, "sanity: TK2 laid out some content")
        tv.setFrameSize(NSSize(width: 300, height: ceil(maxY)))
        tv.diag.noteFit(tv, proposalWidth: 300, result: tv.frame.size)
        let anomalies = tv.diag.collectAnomalies(tv)
        XCTAssertTrue(anomalies.isEmpty, "unexpected anomalies: \(anomalies.map(\.detail))")
    }

    // A shifted bounds origin relocates ALL drawing while frame and layout still read "correct" -
    // exactly the kind of silent offset the detector exists to catch.
    @MainActor
    func testShiftedBoundsOriginIsFlagged() {
        let tv = makeLaidOutTextView()
        tv.setBoundsOrigin(NSPoint(x: 0, y: -40))
        let anomalies = tv.diag.collectAnomalies(tv)
        XCTAssertTrue(anomalies.contains { $0.key == "boundsOrigin" },
                      "expected boundsOrigin anomaly, got: \(anomalies.map(\.key))")
    }

    // A frame height that matches no recent sizeThatFits answer means someone resized the view
    // behind SwiftUI's back (AppKit self-sizing, a stale row cache).
    @MainActor
    func testFrameDivergedFromReportedFitIsFlagged() {
        let tv = makeLaidOutTextView()
        tv.diag.noteFit(tv, proposalWidth: 300, result: tv.frame.size)
        tv.setFrameSize(NSSize(width: 300, height: tv.frame.height + 120))
        let anomalies = tv.diag.collectAnomalies(tv)
        XCTAssertTrue(anomalies.contains { $0.key == "fitMismatch" },
                      "expected fitMismatch anomaly, got: \(anomalies.map(\.key))")
    }

    // Content taller than the view: glyphs would draw past the frame bottom (outside the bubble).
    @MainActor
    func testContentOverflowIsFlagged() {
        let tv = makeLaidOutTextView()
        tv.setFrameSize(NSSize(width: 300, height: 5))
        let anomalies = tv.diag.collectAnomalies(tv)
        XCTAssertTrue(anomalies.contains { $0.key == "overflow" },
                      "expected overflow anomaly, got: \(anomalies.map(\.key))")
    }

    // The snapshot must carry the sections a field diagnosis needs: geometry, TextKit state,
    // the view hierarchy, and the recorded event trail (the setFrameSize above).
    @MainActor
    func testSnapshotCarriesGeometryAndEvents() {
        let tv = makeLaidOutTextView()
        let snapshot = tv.diag.snapshot(tv)
        XCTAssertTrue(snapshot.contains("frame="), "snapshot missing frame: \(snapshot)")
        XCTAssertTrue(snapshot.contains("tk1 usedRect="), "snapshot missing TK1 layout state: \(snapshot)")
        XCTAssertTrue(snapshot.contains("hierarchy:"), "snapshot missing hierarchy: \(snapshot)")
        XCTAssertTrue(snapshot.contains("setFrameSize"), "snapshot missing recorded events: \(snapshot)")
    }

    // The geometry captured live on 2026-07-16: SwiftUI's (unflipped) AppKitPlatformViewHost held the
    // correct 276pt slot but placed the text view with a STALE height at (0, 48, w, 228) - deficit as
    // origin - which composited the glyphs shifted down and overflowing the bubble. Reproduce that
    // exact state around a host and assert the detector names it and the heal restores the invariant
    // (platform view fills its host).
    @MainActor
    private func makeStaleHostedTextView() -> (host: NSView, tv: RichTextTopAlignedTextView) {
        let tv = makeLaidOutTextView()
        tv.snapsToHostBounds = true
        let host = NSView(frame: NSRect(x: 330, y: 98, width: 300, height: 276))   // plain NSView: unflipped, like the live capture
        host.addSubview(tv)
        tv.frame = NSRect(x: 0, y: 48, width: 300, height: 228)
        return (host, tv)
    }

    @MainActor
    func testStaleHostedFrameIsFlaggedAsHostMismatch() {
        let (_, tv) = makeStaleHostedTextView()
        let anomalies = tv.diag.collectAnomalies(tv)
        XCTAssertTrue(anomalies.contains { $0.key == "hostMismatch" },
                      "expected hostMismatch anomaly, got: \(anomalies.map(\.key))")
    }

    @MainActor
    func testSelfHealSnapsFrameToHostBounds() {
        let (host, tv) = makeStaleHostedTextView()
        // No window in a headless test; the guard requires one in production so a detached view never
        // snaps mid-teardown. Exercise the core geometry logic through a window-equipped host instead.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView?.addSubview(host)
        tv.snapToHostBoundsIfNeeded()
        XCTAssertEqual(tv.frame, host.bounds,
                       "self-heal must snap the platform view back to fill its host")
        let anomalies = tv.diag.collectAnomalies(tv)
        XCTAssertFalse(anomalies.contains { $0.key == "hostMismatch" },
                       "healed frame must clear the hostMismatch anomaly")
    }

    // A plain AppKit host (scroll view documentView idiom) legitimately sizes the text view differently:
    // without the SwiftUI-hosting flag neither the anomaly nor the heal may fire.
    @MainActor
    func testNonSwiftUIHostIsExemptFromHostChecks() {
        let (host, tv) = makeStaleHostedTextView()
        tv.snapsToHostBounds = false
        let before = tv.frame
        tv.snapToHostBoundsIfNeeded()
        XCTAssertEqual(tv.frame, before, "heal must not fire for non-SwiftUI hosts")
        let anomalies = tv.diag.collectAnomalies(tv)
        XCTAssertFalse(anomalies.contains { $0.key == "hostMismatch" },
                       "hostMismatch must be gated on SwiftUI hosting")
        _ = host
    }
}
#endif
