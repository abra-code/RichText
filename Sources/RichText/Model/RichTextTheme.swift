// Sources/RichText/Model/RichTextTheme.swift
//
// The visual metrics every renderer reads: TextKit on Apple platforms, GtkTextView on Linux. Lengths are in
// points (CGFloat on Apple platforms; Linux, which has no CoreGraphics, uses Double).

#if canImport(CoreGraphics)
import CoreGraphics

/// A length in points: CGFloat on Apple platforms, Double on Linux.
public typealias RichTextLength = CGFloat
#else
/// A length in points (CGFloat on Apple platforms).
public typealias RichTextLength = Double
#endif

/// Visual metrics. Colors come from the platform (semantic system colors on Apple platforms, the GTK style
/// on Linux), so they follow light and dark appearance.
public struct RichTextTheme: Sendable, Equatable {
    public var baseFontSize: RichTextLength?   // nil => the platform's body text size (Dynamic Type on Apple)
    public var indentStep: RichTextLength
    public var blockSpacing: RichTextLength
    public var listSpacing: RichTextLength
    public var codeCornerRadius: RichTextLength
    public var cellPadding: RichTextLength
    public var syntaxHighlighting: Bool    // color fenced code blocks by language

    public init(baseFontSize: RichTextLength? = nil, indentStep: RichTextLength = 22, blockSpacing: RichTextLength = 9,
                listSpacing: RichTextLength = 3, codeCornerRadius: RichTextLength = 6, cellPadding: RichTextLength = 6,
                syntaxHighlighting: Bool = true) {
        self.baseFontSize = baseFontSize
        self.indentStep = indentStep
        self.blockSpacing = blockSpacing
        self.listSpacing = listSpacing
        self.codeCornerRadius = codeCornerRadius
        self.cellPadding = cellPadding
        self.syntaxHighlighting = syntaxHighlighting
    }

    public static let `default` = RichTextTheme()
}
