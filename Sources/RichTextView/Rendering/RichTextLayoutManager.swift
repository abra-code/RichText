// Sources/RichTextView/Rendering/RichTextLayoutManager.swift
//
// The decoration painter. A custom NSLayoutManager (TextKit 1, cross-platform) that draws the block
// decorations the iOS / macOS text stacks have no native model for: the code-block rounded rectangle,
// the block-quote bar, the thematic-break hairline, and the table grid. Everything is DRAW-ONLY, keyed
// off the marker attributes (RichTextAttributes.swift) - the text itself carries no block structure, so
// selection / copy stay clean and the same attributed string works on both platforms. (TextKit 1 is
// used deliberately: it reuses the drawBackground pattern already verified on macOS. TextKit 2 custom
// layout fragments are the strategic future per the design doc.)

import Foundation

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

final class RichTextLayoutManager: NSLayoutManager {

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)   // inline-code backgrounds
        guard let storage = textStorage, let container = textContainers.first else {
            return
        }
        let containerWidth = container.size.width
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        storage.enumerateAttribute(.rtvCodeBlock, in: charRange) { value, range, _ in
            guard value != nil else {
                return
            }
            var rect = self.markerRect(range, in: container).offsetBy(dx: origin.x, dy: origin.y)
            rect.origin.x = origin.x + 1
            rect.size.width = containerWidth - 2
            fillRoundedRect(rect.insetBy(dx: 0, dy: -3), radius: 6, color: RTVColors.codeFill)
        }

        storage.enumerateAttribute(.rtvRule, in: charRange) { value, range, _ in
            guard value != nil else {
                return
            }
            let rect = self.markerRect(range, in: container).offsetBy(dx: origin.x, dy: origin.y)
            let y = rect.midY.rounded() + 0.5
            strokeLine(from: CGPoint(x: origin.x + 1, y: y), to: CGPoint(x: origin.x + containerWidth - 1, y: y),
                       width: 1, color: RTVColors.separator)
        }

        storage.enumerateAttribute(.rtvQuoteBar, in: charRange) { value, range, _ in
            guard let x = value as? CGFloat else {
                return
            }
            let rect = self.markerRect(range, in: container).offsetBy(dx: origin.x, dy: origin.y)
            let bar = CGRect(x: origin.x + x, y: rect.minY, width: 3, height: rect.height)
            fillRoundedRect(bar, radius: 1.5, color: RTVColors.separator)
        }

        storage.enumerateAttribute(.rtvTableRow, in: charRange) { value, range, _ in
            guard let info = value as? RichTextTableRowInfo, let leftEdge = info.columnEdges.first,
                  let rightEdge = info.columnEdges.last else {
                return
            }
            let rect = self.markerRect(range, in: container).offsetBy(dx: origin.x, dy: origin.y)
            let box = CGRect(x: origin.x + leftEdge, y: rect.minY,
                             width: rightEdge - leftEdge, height: rect.height)
            if info.header {
                fillRect(box, color: RTVColors.codeFill)
            }
            // Vertical column separators (including the outer left / right edges).
            for edge in info.columnEdges {
                let lineX = (origin.x + edge).rounded() + 0.5
                strokeLine(from: CGPoint(x: lineX, y: box.minY), to: CGPoint(x: lineX, y: box.maxY),
                           width: 1, color: RTVColors.separator)
            }
            // Top border on the first row; every row draws its bottom border (rows share edges).
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

    /// Bounding rect of a marked character range, in text-container coordinates.
    private func markerRect(_ charRange: NSRange, in container: NSTextContainer) -> CGRect {
        let glyphs = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        return boundingRect(forGlyphRange: glyphs, in: container)
    }
}

// MARK: - Cross-platform drawing helpers

func fillRoundedRect(_ rect: CGRect, radius: CGFloat, color: RTVColor) {
    color.setFill()
    #if canImport(AppKit)
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    #else
    UIBezierPath(roundedRect: rect, cornerRadius: radius).fill()
    #endif
}

func fillRect(_ rect: CGRect, color: RTVColor) {
    color.setFill()
    #if canImport(AppKit)
    NSBezierPath(rect: rect).fill()
    #else
    UIBezierPath(rect: rect).fill()
    #endif
}

func strokeLine(from start: CGPoint, to end: CGPoint, width: CGFloat, color: RTVColor) {
    color.setStroke()
    #if canImport(AppKit)
    let path = NSBezierPath()
    path.lineWidth = width
    path.move(to: start)
    path.line(to: end)
    path.stroke()
    #else
    let path = UIBezierPath()
    path.lineWidth = width
    path.move(to: start)
    path.addLine(to: end)
    path.stroke()
    #endif
}
