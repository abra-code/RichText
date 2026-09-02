// Sources/RichText/Rendering/RichTextHighlight.swift
//
// Layer 2 of the find stack (see RichTextSearch.swift): painting ranges. `RichTextHighlights` is a value
// the RichText view carries (`.findHighlights(_:)`); the representables hand it to the engine-specific
// applier below. Both appliers are DRAW-ONLY - nothing here touches the text storage, so a query change
// never re-lays-out the document and never trips the representables' content-equality check:
//   - TextKit 1: RichTextLayoutManager keeps the value and paints it in drawBackground, next to the
//     code-block / quote decorations it already draws. (macOS has temporary attributes for this; iOS's
//     NSLayoutManager does not, and one drawing path for both platforms is simpler than two.)
//   - TextKit 2: rendering attributes on the NSTextLayoutManager, which are the API made for exactly
//     this - "attributes that don't affect layout" - and which the custom layout fragment's super.draw
//     honors on both platforms. (A host that also enables NSTextView's own find bar would see its
//     highlights cleared by this: the applier owns the .backgroundColor rendering attribute.) A rendering
//     attribute asks nothing to redraw, so the applier's `invalidateDisplay` follows every change and
//     marks the text view and all its descendants dirty (see there for why nothing less reaches the
//     fragment subviews).
// The current match is painted in a second color, and its frame is reported back so an embedding
// scroller (a chat transcript, a document window) can bring it into view; see RichTextCurrentMatchAnchorKey
// and RichTextMatchFrameReporter.

import Foundation
import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Colors for the highlighted ranges. The defaults are translucent system colors that resolve per
/// appearance (built with a dynamic provider, because `withAlphaComponent` alone flattens an NSColor to
/// the appearance current at the call): the text keeps its label color (the highlight is drawn behind
/// it, never through the storage), so an opaque find-yellow would leave white dark-mode text
/// unreadable on the current match.
public struct RichTextHighlightStyle: Equatable {
    /// Every match.
    public var color: RTVColor
    /// The one match the user is on (`RichTextHighlights.current`).
    public var currentColor: RTVColor

    public init(color: RTVColor, currentColor: RTVColor) {
        self.color = color
        self.currentColor = currentColor
    }

    public static var `default`: RichTextHighlightStyle {
        RichTextHighlightStyle(color: translucent(RTVColor.systemYellow, alpha: 0.35),
                               currentColor: translucent(RTVColor.systemOrange, alpha: 0.55))
    }

    /// `base` at `alpha`, still resolving per appearance.
    static func translucent(_ base: RTVColor, alpha: CGFloat) -> RTVColor {
        #if canImport(AppKit)
        return NSColor(name: nil) { appearance in
            var resolved = base
            appearance.performAsCurrentDrawingAppearance {
                resolved = base.withAlphaComponent(alpha)
            }
            return resolved
        }
        #else
        return UIColor { traits in
            base.resolvedColor(with: traits).withAlphaComponent(alpha)
        }
        #endif
    }
}

/// The ranges to paint, in the rendered string (what `RichTextSearch` returns). Equatable so a view update
/// with the same value is a no-op.
public struct RichTextHighlights: Equatable {
    public var ranges: [NSRange]
    /// Index into `ranges` of the match to paint in `style.currentColor` and to report the frame of; nil
    /// paints every range alike.
    public var current: Int?
    public var style: RichTextHighlightStyle

    public init(ranges: [NSRange], current: Int? = nil, style: RichTextHighlightStyle = .default) {
        self.ranges = ranges
        self.current = current
        self.style = style
    }

    public init(matches: [RichTextMatch], current: Int? = nil, style: RichTextHighlightStyle = .default) {
        self.init(ranges: matches.map(\.range), current: current, style: style)
    }

    public var isEmpty: Bool {
        ranges.isEmpty
    }

    /// The current range, if `current` names one.
    public var currentRange: NSRange? {
        guard let current, ranges.indices.contains(current) else {
            return nil
        }
        return ranges[current]
    }

    /// The ranges clipped to a document of `length` UTF-16 units; a stale range past the end (the
    /// document changed under an old query) paints nothing rather than asserting inside TextKit.
    func clipped(to length: Int) -> [(range: NSRange, isCurrent: Bool)] {
        var out: [(NSRange, Bool)] = []
        for (index, range) in ranges.enumerated() {
            guard let hit = NSIntersectionRange(range, NSRange(location: 0, length: length)).nonEmpty else {
                continue
            }
            out.append((hit, index == current))
        }
        return out
    }
}

extension NSRange {
    var nonEmpty: NSRange? {
        length > 0 ? self : nil
    }
}

/// The frame of the current match, published by the RichText view as an anchor in its own coordinate
/// space so any ancestor can resolve it against its own geometry (`proxy[anchor]` inside a GeometryReader)
/// and scroll it into view. nil when there is no current match, or it has not been laid out yet.
public struct RichTextCurrentMatchAnchorKey: PreferenceKey {
    public static var defaultValue: Anchor<CGRect>? {
        nil
    }

    public static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        if let next = nextValue() {
            value = next
        }
    }
}

// MARK: - Reporting the current match's frame

/// Measures the current match's frame and reports it to the SwiftUI view - lazily, on the next runloop
/// turn, never inside a view update or a sizing pass. A measurement forced during `updateNSView` would
/// lay the document out at whatever width the container happens to have (0 on the first pass), which is
/// exactly the nondeterministic-sizing hazard the sizing code guards against; deferring puts it after
/// SwiftUI's layout has set the real width. Measurements are keyed by (range, container width, storage
/// length): the same key is not re-reported, and a changed key (a resize, text appended after the match,
/// a new current match) is - which is why both the update path and the sizing path call `schedule`.
@MainActor
final class RichTextMatchFrameReporter {
    private struct Key: Equatable {
        let range: NSRange?
        let width: CGFloat
        let length: Int
        let content: Int   // the coordinator's content generation: a same-length replacement changes it
    }

    private var lastKey: Key?
    private var pending = false

    /// Ask for a (re)measurement; coalesces bursts into one deferred pass.
    func schedule(_ measure: @escaping @MainActor () -> (range: NSRange?, width: CGFloat, length: Int, content: Int, frame: () -> CGRect?),
                  report: @escaping @MainActor (CGRect?) -> Void) {
        guard !pending else {
            return
        }
        pending = true
        // A main-actor Task, not DispatchQueue.main.async: it runs after the current update / layout
        // pass just the same, and it can carry these main-actor closures without them being Sendable.
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            self.pending = false
            let measured = measure()
            let key = Key(range: measured.range, width: measured.width, length: measured.length, content: measured.content)
            guard key != self.lastKey else {
                return
            }
            // A different match: say "no frame yet" first, so an embedding scroller that aligns once
            // per match never spends that on the previous match's frame (which would still lie inside
            // the same row when two hits share a long message).
            if measured.range != self.lastKey?.range, self.lastKey != nil {
                report(nil)
            }
            self.lastKey = key
            // No current match: report nil once (the key records it) without touching layout. A container
            // that has no width yet cannot be measured meaningfully; leave the key unset so the sizing
            // pass that gives it a width triggers the measurement.
            guard measured.range != nil else {
                report(nil)
                return
            }
            guard measured.width > 0 else {
                self.lastKey = nil
                return
            }
            report(measured.frame())
        }
    }
}

// MARK: - TextKit 2 applier

@MainActor
enum RichTextHighlightTK2 {

    /// Replace whatever highlight rendering attributes the layout manager carries with `highlights`.
    static func apply(_ highlights: RichTextHighlights?, to layoutManager: NSTextLayoutManager) {
        let documentRange = layoutManager.documentRange
        layoutManager.removeRenderingAttribute(.backgroundColor, for: documentRange)
        guard let highlights, let contentManager = layoutManager.textContentManager else {
            return
        }
        let length = contentManager.offset(from: documentRange.location, to: documentRange.endLocation)
        for (range, isCurrent) in highlights.clipped(to: length) {
            guard let textRange = textRange(range, in: contentManager, documentRange: documentRange) else {
                continue
            }
            let color = isCurrent ? highlights.style.currentColor : highlights.style.color
            layoutManager.setRenderingAttributes([.backgroundColor: color], for: textRange)
        }
    }

    /// Make a rendering-attribute change visible. Setting a rendering attribute changes what the next draw
    /// shows but asks nothing to draw, so without this the highlights appear on the next scroll. Both text
    /// views draw each fragment into a subview of its own (AppKit's viewport element views, UIKit's fragment
    /// views) that is reused across viewport passes, and a dirty flag on the text view itself does not
    /// cascade into them - nor does invalidating the layout of the ranges, the whole document, or asking
    /// the viewport layout controller to lay out again (measured on macOS 26 by counting fragment draws in
    /// the demo: zero for every one of those, one viewport's worth when the descendants are marked). So the
    /// descendants are marked dirty: one repaint of the visible fragments, no layout, whatever the number
    /// of matches (the walk is a handful of views: the containers plus one element view per visible
    /// fragment). The text view itself is marked as well, for an OS version that draws glyphs in its own
    /// `draw(_:)`. Verified on macOS 26; iOS uses the same mechanism and has not been run here.
    #if canImport(AppKit)
    static func invalidateDisplay(in textView: NSTextView) {
        textView.needsDisplay = true
        markDescendantsDirty(textView)
    }

    private static func markDescendantsDirty(_ view: NSView) {
        for subview in view.subviews {
            subview.needsDisplay = true
            markDescendantsDirty(subview)
        }
    }
    #elseif canImport(UIKit)
    static func invalidateDisplay(in textView: UITextView) {
        textView.setNeedsDisplay()
        markDescendantsDirty(textView)
    }

    /// A UITextView is a scroll view, so the walk also meets its indicators and its selection views. An
    /// image view is skipped: setNeedsDisplay is documented as a no-op on one, and skipping it is the
    /// cheap hedge against an internal image-backed view whose contents a forced display could clear.
    private static func markDescendantsDirty(_ view: UIView) {
        for subview in view.subviews where !(subview is UIImageView) {
            subview.setNeedsDisplay()
            markDescendantsDirty(subview)
        }
    }
    #endif

    /// The union of the line-segment frames the range occupies, in the layout manager's container
    /// coordinates; nil for an empty or out-of-range range.
    static func frame(of range: NSRange, in layoutManager: NSTextLayoutManager) -> CGRect? {
        guard let contentManager = layoutManager.textContentManager,
              let textRange = textRange(range, in: contentManager, documentRange: layoutManager.documentRange) else {
            return nil
        }
        layoutManager.ensureLayout(for: textRange)
        var union: CGRect?
        layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: .rangeNotRequired) { _, frame, _, _ in
            union = union.map { $0.union(frame) } ?? frame
            return true
        }
        return union
    }

    private static func textRange(_ range: NSRange, in contentManager: NSTextContentManager,
                                  documentRange: NSTextRange) -> NSTextRange? {
        guard let start = contentManager.location(documentRange.location, offsetBy: range.location),
              let end = contentManager.location(start, offsetBy: range.length) else {
            return nil
        }
        return NSTextRange(location: start, end: end)
    }
}

// MARK: - TextKit 1 geometry

extension RichTextLayoutManager {

    /// The bounding rect of the range in `container` coordinates (the caller adds the text container
    /// origin); nil for an empty or out-of-range range.
    func frame(of range: NSRange, in container: NSTextContainer) -> CGRect? {
        guard let storage = textStorage,
              let clipped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length)).nonEmpty else {
            return nil
        }
        ensureLayout(forCharacterRange: clipped)
        let glyphs = glyphRange(forCharacterRange: clipped, actualCharacterRange: nil)
        return boundingRect(forGlyphRange: glyphs, in: container)
    }
}
