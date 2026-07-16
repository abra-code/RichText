// Sources/RichText/Rendering/RichTextDiagnostics.swift
//
// Field diagnostics for the intermittent "text draws shifted down / outside its bubble" bug (macOS).
// Two earlier fixes (richTextResolvedLayout width policy, textContainerOrigin top pin) each cured one
// observed variant, yet a shifted state still appears in chat transcripts once in a while and has never
// reproduced headless. This instruments the geometry chain the previous fixes could not see:
//
//   - Every RichText text view records a ring buffer of geometry events (frame / bounds mutations,
//     window moves, sizeThatFits probes and results, content swaps) - with call stacks in verbose mode,
//     so the log answers "who moved this view" after the fact.
//   - Before every draw, an anomaly detector cross-checks the layout bookkeeping (usedRect / layout
//     fragments), the compensated textContainerOrigin, the view frame vs the sizes reported to SwiftUI,
//     the bounds origin, and view-vs-layer geometry for the view and its ancestors. Any inconsistency
//     dumps a full snapshot (geometry, TextKit state, superview chain, recent events) to the unified
//     log. Detection is ALWAYS on; it costs a few cached-geometry reads per draw and logs nothing
//     while healthy.
//   - `RichTextDiagnostics.dumpAll()` (also wired to SIGUSR1 when diagnostics are enabled) snapshots
//     every live RichText view on demand - run `kill -USR1 <pid>` the moment the glitch is visible.
//
// Enable event streaming with env RICHTEXT_DIAGNOSTICS=1 (2 = verbose, adds call stacks and text
// prefixes), or set RichTextDiagnostics.mode programmatically. Deliberately env-only: no UserDefaults
// read, so the module never touches CFPreferences / the file system just by rendering text. Watch with:
//   log stream --level debug --predicate 'subsystem == "com.abracode.RichText"'
// (The logger itself lives in RichTextHostSnap.swift, next to the production self-heal that shares it.)

#if canImport(AppKit)

import AppKit
import QuartzCore
import os

@MainActor
public enum RichTextDiagnostics {
    public enum Mode: Int {
        case off = 0
        case on = 1
        case verbose = 2
    }

    /// Diagnostic level. Read once from env RICHTEXT_DIAGNOSTICS; hosts may also set it
    /// programmatically. Deliberately NOT read from UserDefaults - rendering text must never cost a
    /// CFPreferences / file-system hit. Anomaly DETECTION runs even when `.off` - the mode gates only
    /// the per-event streaming, call-stack capture, and the SIGUSR1 dump trigger.
    public static var mode: Mode = initialMode() {
        didSet {
            if mode != .off {
                installSignalHandlerIfNeeded()
            }
        }
    }

    private static func initialMode() -> Mode {
        guard let env = ProcessInfo.processInfo.environment["RICHTEXT_DIAGNOSTICS"] else {
            return .off
        }
        let raw = Int(env) ?? (env.isEmpty ? 0 : 1)
        return Mode(rawValue: max(0, min(2, raw))) ?? .off
    }

    // Weak registry of live RichText text views, for the on-demand dump.
    private static let liveViews = NSHashTable<NSTextView>.weakObjects()
    private static var signalSource: DispatchSourceSignal?

    static func register(_ view: NSTextView) {
        liveViews.add(view)
        if mode != .off {
            installSignalHandlerIfNeeded()
        }
    }

    /// Snapshots every live RichText view to the unified log (info level), regardless of mode.
    /// Wired to SIGUSR1 when diagnostics are enabled, so a visibly-glitched state can be captured
    /// the moment it is seen: `kill -USR1 $(pgrep <AppName>)`.
    public static func dumpAll(reason: String = "requested") {
        let views = liveViews.allObjects
        richTextDiagLog.info("RichText dumpAll (\(reason, privacy: .public)): \(views.count) live view(s)")
        for view in views {
            let snapshot = (view as? RichTextDiagnosableTextView)?.diag.snapshot(view)
                ?? "unrecorded view \(view)"
            emitChunked(snapshot, asError: false)
        }
    }

    /// os_log truncates long dynamic strings (~1KB), which cut the hierarchy and event-trail sections
    /// out of the first field dumps. Emit multi-line text in line-preserving chunks instead, each
    /// tagged (part i/n) when split.
    static func emitChunked(_ text: String, asError: Bool) {
        let limit = 700
        var chunks: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if !current.isEmpty, current.count + line.count + 1 > limit {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        for (index, chunk) in chunks.enumerated() {
            let tagged = chunks.count > 1 ? "(part \(index + 1)/\(chunks.count))\n\(chunk)" : chunk
            if asError {
                richTextDiagLog.error("\(tagged, privacy: .public)")
            } else {
                richTextDiagLog.info("\(tagged, privacy: .public)")
            }
        }
    }

    // Side effect, by design: enabling diagnostics commandeers SIGUSR1 for the whole process (the
    // default disposition is replaced with SIG_IGN and a dispatch source). Do not enable in a host
    // that uses SIGUSR1 for something else.
    private static func installSignalHandlerIfNeeded() {
        guard signalSource == nil else {
            return
        }
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                dumpAll(reason: "SIGUSR1")
            }
        }
        source.resume()
        signalSource = source
    }
}

/// The macOS RichText text views (TK1's RichTextTopAlignedTextView, TK2's SelectableTextView) expose
/// their recorder through this so the representables and dumpAll reach it without knowing the class.
/// (The production self-heal lives separately in RichTextHostSnap.swift.)
@MainActor
protocol RichTextDiagnosableTextView: NSTextView {
    var diag: RichTextViewDiagnostics { get }
}

/// Per-view geometry recorder + anomaly detector. Owned by the text view; all methods take the view
/// as a parameter (no back-reference), main-thread only like the view itself.
@MainActor
final class RichTextViewDiagnostics {

    private struct Event {
        let time: CFAbsoluteTime
        let kind: String
        let detail: String
        let stack: String?
    }

    private var events: [Event] = []
    private static let eventCapacity = 24

    // Recent sizeThatFits results: SwiftUI probes several widths per pass, and the frame it finally
    // sets should match ONE of them. Compared by the draw-time check. Kept LRU-deduped (SwiftUI
    // re-probes the same widths every pass; naive appends would evict the one matching answer).
    private var recentFits: [(proposal: String, size: CGSize)] = []
    private static let fitCapacity = 12

    private var lastAnomalySignature = ""
    private var lastDumpTime: CFAbsoluteTime = 0

    // MARK: - Event recording

    func note(_ view: NSTextView, _ kind: String, _ detail: String) {
        var stack: String?
        if RichTextDiagnostics.mode == .verbose {
            stack = Thread.callStackSymbols.dropFirst(2).prefix(12).joined(separator: "\n        ")
        }
        events.append(Event(time: CFAbsoluteTimeGetCurrent(), kind: kind, detail: detail, stack: stack))
        if events.count > Self.eventCapacity {
            events.removeFirst()
        }
        if RichTextDiagnostics.mode != .off {
            richTextDiagLog.debug("\(self.viewTag(view), privacy: .public) \(kind, privacy: .public) \(detail, privacy: .public)")
        }
    }

    func noteFrameSize(_ view: NSTextView, from old: NSSize, to new: NSSize) {
        guard old != new else {
            return
        }
        note(view, "setFrameSize", "\(fmt(old)) -> \(fmt(new))")
    }

    func noteFrameOrigin(_ view: NSTextView, from old: NSPoint, to new: NSPoint) {
        guard old != new else {
            return
        }
        note(view, "setFrameOrigin", "\(fmt(old)) -> \(fmt(new))")
    }

    func noteBoundsOrigin(_ view: NSTextView, from old: NSPoint, to new: NSPoint) {
        guard old != new else {
            return
        }
        note(view, "setBoundsOrigin", "\(fmt(old)) -> \(fmt(new))")
    }

    func noteFit(_ view: NSTextView, proposalWidth: CGFloat?, result: CGSize) {
        let proposal = proposalWidth.map { fmt($0) } ?? "nil"
        // LRU dedup: a repeat of an identical probe/answer refreshes its slot instead of appending,
        // so a burst of identical probes cannot evict the distinct answer the final frame matches.
        if let existing = recentFits.firstIndex(where: { $0.proposal == proposal && $0.size == result }) {
            recentFits.remove(at: existing)
        }
        recentFits.append((proposal: proposal, size: result))
        if recentFits.count > Self.fitCapacity {
            recentFits.removeFirst()
        }
        note(view, "sizeThatFits", "proposal.w=\(proposal) -> \(fmt(result)) live=\(fmt(view.bounds.size))")
    }

    // MARK: - Draw-time anomaly check

    /// Called from viewWillDraw (layout is valid for the drawn region). Logs a full snapshot when the
    /// anomaly set changes, and re-logs at most every 2s while a state stays anomalous.
    func checkAndReport(_ view: NSTextView) {
        let anomalies = collectAnomalies(view)
        let signature = anomalies.map(\.key).joined(separator: ",")
        let now = CFAbsoluteTimeGetCurrent()
        if signature == lastAnomalySignature {
            if !anomalies.isEmpty, now - lastDumpTime > 2 {
                lastDumpTime = now
                RichTextDiagnostics.emitChunked(snapshot(view, anomalies: anomalies), asError: true)
            }
            return
        }
        if anomalies.isEmpty {
            richTextDiagLog.info("\(self.viewTag(view), privacy: .public) anomalies cleared (was: \(self.lastAnomalySignature, privacy: .public))")
        } else {
            lastDumpTime = now
            RichTextDiagnostics.emitChunked(snapshot(view, anomalies: anomalies), asError: true)
        }
        lastAnomalySignature = signature
    }

    /// The cross-checks. Each returned entry is (stable key, human detail). All reads are cached
    /// geometry - nothing here forces layout (fragment enumeration omits ensuresLayout; line fragment
    /// reads pass withoutAdditionalLayout).
    func collectAnomalies(_ view: NSTextView) -> [(key: String, detail: String)] {
        var anomalies: [(key: String, detail: String)] = []
        let bounds = view.bounds
        let frame = view.frame

        // The view's own coordinate system: a non-zero bounds origin shifts ALL drawing.
        if abs(bounds.origin.x) > 0.5 || abs(bounds.origin.y) > 0.5 {
            anomalies.append(("boundsOrigin", "boundsOrigin=\(fmt(bounds.origin))"))
        }

        // RichText configures its text views with a zero inset; drift would offset every glyph while
        // the origin compensation (which is inset-relative) still reads "correct".
        let inset = view.textContainerInset
        if abs(inset.width) > 0.5 || abs(inset.height) > 0.5 {
            anomalies.append(("insetDrift", "textContainerInset=\(fmt(inset))"))
        }

        // Under SwiftUI hosting the platform view must FILL its host (the diagnosed live failure: a
        // stale fitting height left the view at (0, deficit, w, staleH) inside a correctly-sized host).
        // Gated on snapsToHostBounds so a plain AppKit host (scroll view documentView) never trips it.
        if let host = view.superview, (view as? RichTextHostSnapping)?.snapsToHostBounds == true {
            let target = host.bounds
            if abs(frame.origin.x - target.origin.x) > 0.5 || abs(frame.origin.y - target.origin.y) > 0.5
                || abs(frame.width - target.width) > 0.5 || abs(frame.height - target.height) > 0.5 {
                anomalies.append(("hostMismatch", "frame=\(fmt(frame)) host.bounds=\(fmt(target))"))
            }
        }

        // Frame vs what sizeThatFits told SwiftUI: if the height matches NO recent answer, someone
        // (AppKit self-sizing, a stale SwiftUI cache) changed the frame behind SwiftUI's back.
        if !recentFits.isEmpty, !recentFits.contains(where: { abs($0.size.height - frame.height) <= 1 }) {
            let fits = recentFits.map { "\($0.proposal)->\(fmt($0.size))" }.joined(separator: " ")
            anomalies.append(("fitMismatch", "frame.h=\(fmt(frame.height)) matches no recent fit [\(fits)]"))
        }

        // View vs its backing layer (model layer, not presentation): a desync draws content somewhere
        // other than the layout rect while every frame value still reads "correct". Beyond the frame,
        // a non-identity transform / sublayerTransform or a shifted contentsRect also relocates pixels
        // without touching any frame value - check those too.
        if let layer = view.layer {
            if !approxEqual(layer.frame, frame) {
                anomalies.append(("layerDesync", "layer.frame=\(fmt(layer.frame)) view.frame=\(fmt(frame))"))
            }
            if !CATransform3DIsIdentity(layer.transform) {
                anomalies.append(("layerTransform", "layer.transform not identity"))
            }
            if !CATransform3DIsIdentity(layer.sublayerTransform) {
                anomalies.append(("layerSublayerTransform", "layer.sublayerTransform not identity"))
            }
            if layer.contentsRect != CGRect(x: 0, y: 0, width: 1, height: 1) {
                anomalies.append(("layerContentsRect", "layer.contentsRect=\(fmt(layer.contentsRect))"))
            }
        }

        // Ancestors (SwiftUI hosting chain): layer desyncs, transforms, and stray bounds origins.
        // NSClipView is exempt from the bounds check - its bounds origin IS the scroll position.
        var ancestor = view.superview
        var depth = 0
        while let current = ancestor, depth < 6 {
            if let layer = current.layer {
                if !approxEqual(layer.frame, current.frame) {
                    anomalies.append(("ancestorLayerDesync",
                                      "\(type(of: current)) layer.frame=\(fmt(layer.frame)) frame=\(fmt(current.frame))"))
                }
                if !CATransform3DIsIdentity(layer.transform) {
                    anomalies.append(("ancestorLayerTransform", "\(type(of: current)) layer.transform not identity"))
                }
            }
            if !(current is NSClipView),
               abs(current.bounds.origin.x) > 0.5 || abs(current.bounds.origin.y) > 0.5 {
                anomalies.append(("ancestorBoundsOrigin",
                                  "\(type(of: current)) bounds.origin=\(fmt(current.bounds.origin))"))
            }
            ancestor = current.superview
            depth += 1
        }

        if let textLayoutManager = view.textLayoutManager {
            // TextKit 2. First/last fragment geometry WITHOUT forcing layout (no ensuresLayout), so the
            // walk sees only fragments laid out so far; overflow is judged only when the walk reached
            // the end of the document (a partial extent would under-report and cannot be trusted).
            var firstMinY: CGFloat?
            var maxY: CGFloat = 0
            var lastEnd: (any NSTextLocation)?
            textLayoutManager.enumerateTextLayoutFragments(from: textLayoutManager.documentRange.location,
                                                           options: []) { fragment in
                if firstMinY == nil {
                    firstMinY = fragment.layoutFragmentFrame.minY
                }
                maxY = max(maxY, fragment.layoutFragmentFrame.maxY)
                lastEnd = fragment.rangeInElement.endLocation
                return true
            }
            if let firstMinY, abs(firstMinY) > 0.5 {
                anomalies.append(("tk2FirstFragmentMinY", "firstFragment.minY=\(fmt(firstMinY))"))
            }
            let documentEnd = textLayoutManager.documentRange.endLocation
            if let lastEnd, lastEnd.compare(documentEnd) == .orderedSame {
                let used = maxY - (firstMinY ?? 0)
                if used - bounds.height > 1.5 {
                    anomalies.append(("tk2Overflow", "fragments.h=\(fmt(used)) bounds.h=\(fmt(bounds.height))"))
                }
            }
        } else if let layoutManager = view.layoutManager, let container = view.textContainer {
            // TextKit 1 (the chat default), or a TK2 view after the NSTextTable downgrade.
            let used = layoutManager.usedRect(for: container)
            if abs(used.minY) > 0.5 {
                anomalies.append(("usedMinY", "usedRect.minY=\(fmt(used.minY))"))
            }
            if used.height - bounds.height > 1.5 {
                anomalies.append(("overflow", "usedRect.h=\(fmt(used.height)) bounds.h=\(fmt(bounds.height))"))
            }
            if abs(container.size.width - bounds.width) > 1.5 {
                anomalies.append(("containerWidth",
                                  "container.w=\(fmt(container.size.width)) bounds.w=\(fmt(bounds.width))"))
            }
            // Is the top-pin compensation live? origin.y + usedRect.minY must land at the inset.
            let origin = view.textContainerOrigin
            if abs(origin.y + used.minY - view.textContainerInset.height) > 0.5 {
                anomalies.append(("originUncompensated",
                                  "origin.y=\(fmt(origin.y)) usedRect.minY=\(fmt(used.minY)) inset=\(fmt(view.textContainerInset.height))"))
            }
            // Bookkeeping consistency: the first line fragment's rect must agree with usedRect. A
            // mismatch means stale fragment geometry (e.g. new text laid out below a ghost of the old).
            if layoutManager.numberOfGlyphs > 0 {
                var effectiveRange = NSRange()
                let firstLine = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: &effectiveRange,
                                                               withoutAdditionalLayout: true)
                if firstLine.minY - used.minY > 0.5 {
                    anomalies.append(("fragmentVsUsed",
                                      "firstLine.minY=\(fmt(firstLine.minY)) usedRect.minY=\(fmt(used.minY))"))
                }
            }
            // Deliberately NOT an anomaly: a partially-laid-out tail (firstUnlaidGlyphIndex <
            // numberOfGlyphs) is a normal transient during streaming growth. The snapshot records it.
        }
        return anomalies
    }

    // MARK: - Snapshot

    func snapshot(_ view: NSTextView) -> String {
        snapshot(view, anomalies: collectAnomalies(view))
    }

    private func snapshot(_ view: NSTextView, anomalies: [(key: String, detail: String)]) -> String {
        var lines: [String] = []
        let headline = anomalies.isEmpty ? "OK" : "ANOMALIES: " + anomalies.map(\.detail).joined(separator: "; ")
        lines.append("RichText \(viewTag(view)) \(headline)")
        lines.append("  text: \(textFingerprint(view.textStorage?.string ?? ""))")
        lines.append("  frame=\(fmt(view.frame)) bounds.origin=\(fmt(view.bounds.origin)) inset=\(fmt(view.textContainerInset))")
        if let host = view.superview {
            lines.append("  host: \(type(of: host)) bounds=\(fmt(host.bounds))\(host.isFlipped ? "" : " UNFLIPPED") snaps=\((view as? RichTextHostSnapping)?.snapsToHostBounds ?? false)")
        }
        if let container = view.textContainer {
            let height = container.size.height > 1e12 ? "unbounded" : fmt(container.size.height)
            lines.append("  container.size=(\(fmt(container.size.width))x\(height)) tracksWidth=\(container.widthTracksTextView) origin=\(fmt(view.textContainerOrigin))")
        }
        if let layer = view.layer {
            lines.append("  layer.frame=\(fmt(layer.frame)) position=\(fmt(layer.position)) anchor=\(fmt(layer.anchorPoint)) masksToBounds=\(layer.masksToBounds) flippedGeom=\(layer.isGeometryFlipped)")
        }
        if !recentFits.isEmpty {
            lines.append("  recentFits: " + recentFits.map { "\($0.proposal)->\(fmt($0.size))" }.joined(separator: " "))
        }
        if let textLayoutManager = view.textLayoutManager {
            var first: CGRect?
            var last: CGRect?
            textLayoutManager.enumerateTextLayoutFragments(from: textLayoutManager.documentRange.location,
                                                           options: []) { fragment in
                if first == nil {
                    first = fragment.layoutFragmentFrame
                }
                last = fragment.layoutFragmentFrame
                return true
            }
            let viewport = textLayoutManager.textViewportLayoutController.viewportBounds
            lines.append("  tk2 firstFragment=\(first.map(fmt) ?? "none") lastFragment=\(last.map(fmt) ?? "none") viewport=\(fmt(viewport))")
        } else if let layoutManager = view.layoutManager, let container = view.textContainer {
            let used = layoutManager.usedRect(for: container)
            var line = "  tk1 usedRect=\(fmt(used)) glyphs=\(layoutManager.numberOfGlyphs) firstUnlaid=\(layoutManager.firstUnlaidGlyphIndex())"
            if layoutManager.numberOfGlyphs > 0 {
                var effectiveRange = NSRange()
                let firstLine = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: &effectiveRange,
                                                               withoutAdditionalLayout: true)
                let lastLine = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.numberOfGlyphs - 1,
                                                              effectiveRange: &effectiveRange,
                                                              withoutAdditionalLayout: true)
                line += " firstLine=\(fmt(firstLine)) lastLine=\(fmt(lastLine))"
            }
            lines.append(line)
        }
        lines.append("  hierarchy:")
        var current: NSView? = view
        var depth = 0
        while let node = current, depth < 10 {
            var line = "    \(depth) \(type(of: node)) frame=\(fmt(node.frame))"
            if node.bounds.origin != .zero {
                line += " bounds.origin=\(fmt(node.bounds.origin))"
            }
            if !node.isFlipped {
                line += " UNFLIPPED"
            }
            if let layer = node.layer {
                if !approxEqual(layer.frame, node.frame) {
                    line += " layer.frame=\(fmt(layer.frame)) DESYNC"
                }
                if layer.masksToBounds {
                    line += " masks"
                }
            }
            lines.append(line)
            current = node.superview
            depth += 1
        }
        if let window = view.window {
            lines.append("  window frame=\(fmt(window.frame)) contentView.h=\(fmt(window.contentView?.bounds.height ?? -1))")
        } else {
            lines.append("  window=nil")
        }
        if !events.isEmpty {
            lines.append("  recent events:")
            let now = CFAbsoluteTimeGetCurrent()
            for event in events {
                lines.append("    \(String(format: "%+8.3fs", event.time - now)) \(event.kind) \(event.detail)")
                if let stack = event.stack {
                    lines.append("        \(stack)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Formatting

    private func viewTag(_ view: NSTextView) -> String {
        let engine = view.textLayoutManager != nil ? "tk2" : "tk1"
        return "[\(engine) \(Unmanaged.passUnretained(view).toOpaque())]"
    }

    /// Length + stable hash always; a short content prefix only in verbose mode (chat text is user data).
    private func textFingerprint(_ string: String) -> String {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = (hash &* 33) ^ UInt64(byte)
        }
        var fingerprint = "len=\(string.count) hash=\(String(hash & 0xffff_ffff, radix: 16))"
        if RichTextDiagnostics.mode == .verbose {
            let prefix = string.prefix(24).replacingOccurrences(of: "\n", with: "\\n")
            fingerprint += " \"\(prefix)\""
        }
        return fingerprint
    }

    private func approxEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1.0) -> Bool {
        abs(a.origin.x - b.origin.x) <= tolerance && abs(a.origin.y - b.origin.y) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    private func fmt(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }

    private func fmt(_ point: CGPoint) -> String {
        "(\(fmt(point.x)),\(fmt(point.y)))"
    }

    private func fmt(_ size: CGSize) -> String {
        "(\(fmt(size.width))x\(fmt(size.height)))"
    }

    private func fmt(_ rect: CGRect) -> String {
        "(\(fmt(rect.origin.x)),\(fmt(rect.origin.y)) \(fmt(rect.width))x\(fmt(rect.height)))"
    }
}

#endif
