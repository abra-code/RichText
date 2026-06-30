// Sources/RichTextView/Rendering/RichTextAttributes.swift
//
// Platform abstractions + the semantic MARKER attributes that the attributed-string builder writes and
// the custom layout manager reads. Markers carry NO native block structure (no NSTextTable / NSTextBlock)
// - they are draw-only hints - so the same NSAttributedString works on iOS and macOS and the exported
// RTF stays clean (tables are emitted by the serializer, not baked into the text).

import Foundation

#if canImport(AppKit)
import AppKit
public typealias RTVFont = NSFont
public typealias RTVColor = NSColor
#elseif canImport(UIKit)
import UIKit
public typealias RTVFont = UIFont
public typealias RTVColor = UIColor
#endif

extension NSAttributedString.Key {
    /// Marks a code-block paragraph; the layout manager fills a rounded rectangle behind it.
    static let rtvCodeBlock = NSAttributedString.Key("rtv.codeBlock")
    /// Marks a thematic-break paragraph; the layout manager draws a hairline across it.
    static let rtvRule = NSAttributedString.Key("rtv.rule")
    /// Marks a block-quote paragraph; value is the bar's x gutter (CGFloat). The layout manager draws a
    /// vertical bar in the gutter spanning the paragraph.
    static let rtvQuoteBar = NSAttributedString.Key("rtv.quoteBar")
    /// Marks a table-row paragraph; value is a `RichTextTableRowInfo` describing the grid to draw.
    static let rtvTableRow = NSAttributedString.Key("rtv.tableRow")
}

/// Per-row table geometry the layout manager uses to draw the grid (T1: tab-stop rows + drawn borders).
/// `columnEdges` are absolute x-positions (in text-container coordinates) of every column boundary,
/// including the left (0) and the right edge. `header` rows get a tinted background.
final class RichTextTableRowInfo {
    let columnEdges: [CGFloat]
    let header: Bool
    let firstRow: Bool
    let lastRow: Bool
    init(columnEdges: [CGFloat], header: Bool, firstRow: Bool, lastRow: Bool) {
        self.columnEdges = columnEdges
        self.header = header
        self.firstRow = firstRow
        self.lastRow = lastRow
    }
}

/// Visual metrics + colors. Cross-platform; `NSColor` and `UIColor` name semantic colors differently.
public struct RichTextTheme: Sendable {
    public var baseFontSize: CGFloat?      // nil => Dynamic Type body
    public var indentStep: CGFloat
    public var blockSpacing: CGFloat
    public var listSpacing: CGFloat
    public var codeCornerRadius: CGFloat
    public var cellPadding: CGFloat

    public init(baseFontSize: CGFloat? = nil, indentStep: CGFloat = 22, blockSpacing: CGFloat = 9,
                listSpacing: CGFloat = 3, codeCornerRadius: CGFloat = 6, cellPadding: CGFloat = 6) {
        self.baseFontSize = baseFontSize
        self.indentStep = indentStep
        self.blockSpacing = blockSpacing
        self.listSpacing = listSpacing
        self.codeCornerRadius = codeCornerRadius
        self.cellPadding = cellPadding
    }

    public static let `default` = RichTextTheme()
}

enum RTVColors {
    static var label: RTVColor {
        #if canImport(AppKit)
        return .labelColor
        #else
        return .label
        #endif
    }
    static var secondary: RTVColor {
        #if canImport(AppKit)
        return .secondaryLabelColor
        #else
        return .secondaryLabel
        #endif
    }
    static var link: RTVColor {
        #if canImport(AppKit)
        return .linkColor
        #else
        return .link
        #endif
    }
    static var codeFill: RTVColor {
        #if canImport(AppKit)
        return .quaternaryLabelColor
        #else
        return .quaternarySystemFill
        #endif
    }
    static var separator: RTVColor {
        #if canImport(AppKit)
        return .separatorColor
        #else
        return .separator
        #endif
    }
}

enum RTVFonts {
    static func body(_ size: CGFloat?) -> RTVFont {
        if let size {
            return .systemFont(ofSize: size)
        }
        return .preferredFont(forTextStyle: .body)
    }

    static func monospaced(_ size: CGFloat) -> RTVFont {
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func heading(_ level: Int) -> RTVFont {
        #if canImport(AppKit)
        let style: NSFont.TextStyle
        #else
        let style: UIFont.TextStyle
        #endif
        switch level {
        case 1: style = .title1
        case 2: style = .title2
        case 3: style = .title3
        case 4: style = .headline
        default: style = .subheadline
        }
        return .preferredFont(forTextStyle: style)
    }

    static func withTraits(_ base: RTVFont, bold: Bool, italic: Bool) -> RTVFont {
        #if canImport(AppKit)
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold {
            traits.insert(.bold)
        }
        if italic {
            traits.insert(.italic)
        }
        if traits.isEmpty {
            return base
        }
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
        #else
        var traits = base.fontDescriptor.symbolicTraits
        if bold {
            traits.insert(.traitBold)
        }
        if italic {
            traits.insert(.traitItalic)
        }
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else {
            return base
        }
        return UIFont(descriptor: descriptor, size: base.pointSize)
        #endif
    }
}
