// Sources/RichTextView/Rendering/RichTextLayoutFragment.swift
//
// The TextKit 2 decoration painter - the strategic counterpart to RichTextLayoutManager (TextKit 1).
// A custom NSTextLayoutFragment draws the block decorations the text stacks have no native model for
// (code-block rounded rectangle, block-quote bar, thematic-break hairline, table grid), keyed off the
// same draw-only marker attributes (RichTextAttributes.swift). Because the builder makes each decorated
// block a single paragraph (code lines joined with U+2028; one paragraph per table row), every marked
// region maps to exactly one layout fragment, so a fragment reads its own paragraph's markers and draws
// them - mirroring the TextKit 1 math one-to-one. RichTextFragmentProvider is the layout-manager delegate
// that vends these fragments. The cross-platform drawing helpers live in RichTextLayoutManager.swift.

import Foundation

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Metrics the fragment needs that are not encoded in the attributed string (everything else - colors,
/// quote-bar x, table geometry - rides on the marker attributes).
struct RichTextDecorationMetrics {
    var codeCornerRadius: CGFloat = 6
}

/// A layout fragment that paints the block decorations behind its text.
final class RichTextLayoutFragment: NSTextLayoutFragment {
    var metrics = RichTextDecorationMetrics()

    private struct Decorations {
        var codeBlock = false
        var rule = false
        var quoteBarX: CGFloat?
        var tableRow: RichTextTableRowInfo?
        var any: Bool {
            return codeBlock || rule || quoteBarX != nil || tableRow != nil
        }
    }

    private lazy var decorations: Decorations = readDecorations()

    private func readDecorations() -> Decorations {
        var found = Decorations()
        guard let paragraph = textElement as? NSTextParagraph else {
            return found
        }
        let attributed = paragraph.attributedString
        guard attributed.length > 0 else {
            return found
        }
        let attributes = attributed.attributes(at: 0, effectiveRange: nil)
        if attributes[.rtvCodeBlock] != nil {
            found.codeBlock = true
        }
        if attributes[.rtvRule] != nil {
            found.rule = true
        }
        if let x = attributes[.rtvQuoteBar] as? CGFloat {
            found.quoteBarX = x
        }
        if let info = attributes[.rtvTableRow] as? RichTextTableRowInfo {
            found.tableRow = info
        }
        return found
    }

    // MARK: - Geometry (fragment-local coordinates)

    private var containerWidth: CGFloat {
        return textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
    }

    /// Union of the line typographic bounds - the vertical extent the decorations hug, matching the
    /// TextKit 1 path which used the glyph bounding rect (excludes trailing paragraph spacing).
    private var textBounds: CGRect {
        var union = CGRect.null
        for line in textLineFragments {
            union = union.union(line.typographicBounds)
        }
        if union.isNull {
            return CGRect(origin: .zero, size: layoutFragmentFrame.size)
        }
        return union
    }

    /// Fragment-local x of the text container's left edge (container x == 0). Decorations that span the
    /// full container width (code background, hairline, table) anchor here, independent of paragraph indent.
    private var containerLeftLocalX: CGFloat {
        return -layoutFragmentFrame.minX
    }

    // The fragment's drawing is clipped to renderingSurfaceBounds, so it must be grown to contain any
    // decoration that reaches outside the text (full-width fills, the quote bar in the left gutter).
    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        let found = decorations
        guard found.any else {
            return bounds
        }
        let text = textBounds
        let left = containerLeftLocalX
        var extra = CGRect.null
        if found.codeBlock {
            extra = extra.union(CGRect(x: left, y: text.minY - 4, width: containerWidth, height: text.height + 8))
        }
        if found.rule {
            extra = extra.union(CGRect(x: left, y: text.midY - 1, width: containerWidth, height: 2))
        }
        if let x = found.quoteBarX {
            extra = extra.union(CGRect(x: left + x, y: text.minY, width: 3, height: text.height))
        }
        if let info = found.tableRow, let leftEdge = info.columnEdges.first, let rightEdge = info.columnEdges.last {
            extra = extra.union(CGRect(x: left + leftEdge - 1, y: text.minY - 1,
                                       width: (rightEdge - leftEdge) + 2, height: text.height + 2))
        }
        if !extra.isNull {
            bounds = bounds.union(extra)
        }
        return bounds
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        let found = decorations
        if found.any {
            withGraphicsContext(context) {
                drawDecorations(found, at: point)
            }
        }
        super.draw(at: point, in: context)
    }

    private func drawDecorations(_ found: Decorations, at point: CGPoint) {
        let text = textBounds
        let left = point.x + containerLeftLocalX
        let top = point.y

        if found.codeBlock {
            let rect = CGRect(x: left + 1, y: top + text.minY - 3, width: containerWidth - 2, height: text.height + 6)
            fillRoundedRect(rect, radius: metrics.codeCornerRadius, color: RTVColors.codeFill)
        }

        if found.rule {
            let y = (top + text.midY).rounded() + 0.5
            strokeLine(from: CGPoint(x: left + 1, y: y), to: CGPoint(x: left + containerWidth - 1, y: y),
                       width: 1, color: RTVColors.separator)
        }

        if let x = found.quoteBarX {
            let bar = CGRect(x: left + x, y: top + text.minY, width: 3, height: text.height)
            fillRoundedRect(bar, radius: 1.5, color: RTVColors.separator)
        }

        if let info = found.tableRow, let leftEdge = info.columnEdges.first, let rightEdge = info.columnEdges.last {
            let box = CGRect(x: left + leftEdge, y: top + text.minY, width: rightEdge - leftEdge, height: text.height)
            if info.header {
                fillRect(box, color: RTVColors.codeFill)
            }
            for edge in info.columnEdges {
                let lineX = (left + edge).rounded() + 0.5
                strokeLine(from: CGPoint(x: lineX, y: box.minY), to: CGPoint(x: lineX, y: box.maxY),
                           width: 1, color: RTVColors.separator)
            }
            if info.firstRow {
                let topY = box.minY.rounded() + 0.5
                strokeLine(from: CGPoint(x: box.minX, y: topY), to: CGPoint(x: box.maxX, y: topY),
                           width: 1, color: RTVColors.separator)
            }
            let bottomY = box.maxY.rounded() + 0.5
            strokeLine(from: CGPoint(x: box.minX, y: bottomY), to: CGPoint(x: box.maxX, y: bottomY),
                       width: 1, color: RTVColors.separator)
        }
    }

    // The drawing helpers (fillRoundedRect / fillRect / strokeLine) paint into the CURRENT graphics
    // context, but draw(at:in:) hands us an explicit CGContext that is not necessarily current - so make
    // it current for the duration of the decoration drawing.
    private func withGraphicsContext(_ context: CGContext, _ body: () -> Void) {
        #if canImport(AppKit)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
        #else
        UIGraphicsPushContext(context)
        body()
        UIGraphicsPopContext()
        #endif
    }
}

/// The TextKit 2 layout-manager delegate: vends a `RichTextLayoutFragment` for every text element so each
/// paragraph can paint its own decorations. Held strongly by the view's coordinator (the layout manager
/// keeps only a weak reference to its delegate).
final class RichTextFragmentProvider: NSObject, NSTextLayoutManagerDelegate {
    let metrics: RichTextDecorationMetrics

    init(metrics: RichTextDecorationMetrics) {
        self.metrics = metrics
    }

    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager,
                           textLayoutFragmentFor location: NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        let fragment = RichTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
        fragment.metrics = metrics
        return fragment
    }
}
