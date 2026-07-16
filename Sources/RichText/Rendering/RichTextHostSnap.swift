// Sources/RichText/Rendering/RichTextHostSnap.swift
//
// PRODUCTION fix (not diagnostics) for the intermittent shifted-bubble bug, root-caused from a live
// field capture on 2026-07-16 (see Private/Commit_Notes_LayoutShift_Fix.md): SwiftUI's
// AppKitPlatformViewHost (an UNFLIPPED host view) can apply a STALE fitting height from an earlier
// width probe, placing the text view at (0, deficit, width, staleHeight) inside a correctly-sized
// host - and AppKit's view-to-layer sync can then leave the backing layer behind, compositing the
// glyphs shifted down and overflowing the bubble, with hit-testing (view frame) and drawing (layer)
// disagreeing.
//
// RichText cannot prevent the hosting defect, but the invariant is simple and every healthy layout
// pass maintains it: under SwiftUI hosting the platform view exactly FILLS its host. So the text
// views restore it themselves on the next draw. The snap goes through the normal setFrameOrigin /
// setFrameSize path, which also re-syncs the stale backing layer.

#if canImport(AppKit)

import AppKit
import os

/// One shared log handle for the layout-shift work: heal notices here, anomaly dumps in
/// RichTextDiagnostics - one predicate (subsystem com.abracode.RichText) finds everything.
let richTextDiagLog = Logger(subsystem: "com.abracode.RichText", category: "LayoutShift")

/// Adopted by the macOS RichText text views. `snapsToHostBounds` is set true ONLY by the SwiftUI
/// representables' makeNSView: SwiftUI's platform-view adaptor always sizes the platform view to
/// fill its host, so a diverging frame is a hosting defect, never intent. It stays false for plain
/// AppKit hosts (e.g. a scroll view's documentView, where frame != superview.bounds is normal).
@MainActor
protocol RichTextHostSnapping: NSTextView {
    var snapsToHostBounds: Bool { get set }
}

extension RichTextHostSnapping {
    /// Self-heal: snap the frame back to `superview.bounds` when SwiftUI hosting left it diverged.
    /// Runs from viewWillDraw - post-layout, so a legitimate mid-update transient never triggers it -
    /// and is idempotent (no-op within 0.5pt). It cannot fight SwiftUI: the target IS where the
    /// adaptor puts the view in every healthy pass.
    func snapToHostBoundsIfNeeded() {
        guard snapsToHostBounds, window != nil, let host = superview else {
            return
        }
        let target = host.bounds
        guard target.width > 0.5, target.height > 0.5, !frameApproxEqualToHost(target) else {
            return
        }
        let detail = "frame=\(NSStringFromRect(frame)) -> host.bounds=\(NSStringFromRect(target))"
        (self as? RichTextDiagnosableTextView)?.diag.note(self, "selfHeal", detail)
        // Unconditional and at notice level so it PERSISTS in the unified log: a heal means the
        // hosting bug bit again in the field, and that must stay observable even with diagnostics
        // off - otherwise the fix would silently mask recurrences.
        richTextDiagLog.notice("selfHeal \(String(describing: Unmanaged.passUnretained(self).toOpaque()), privacy: .public) \(detail, privacy: .public)")
        setFrameOrigin(target.origin)
        setFrameSize(target.size)
    }

    private func frameApproxEqualToHost(_ target: NSRect) -> Bool {
        abs(frame.origin.x - target.origin.x) <= 0.5 && abs(frame.origin.y - target.origin.y) <= 0.5
            && abs(frame.width - target.width) <= 0.5 && abs(frame.height - target.height) <= 0.5
    }
}

#endif
