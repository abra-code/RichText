// Sources/RichText/Rendering/RichTextSyntaxHighlighter.swift
//
// A small, dependency-free syntax highlighter for fenced code blocks (design doc P5). The lexer
// (RichTextSyntaxTokenizer.swift) is platform-independent; this file applies its tokens on Apple platforms.
// Output is plain `.foregroundColor` runs, so it is engine-agnostic: both the TextKit 1 and TextKit 2
// backends render it for free, behind the same code-block card.
//
// The colors are system colors, so they adapt to dark mode automatically on both platforms.

import Foundation

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

enum RTVSyntaxColors {
    static var keyword: RTVColor { .systemPurple }
    static var string: RTVColor { .systemRed }
    static var number: RTVColor { .systemBlue }
    static var comment: RTVColor { .systemGreen }
}

extension RichTextSyntaxHighlighter {
    /// Apply syntax colors to `attributed`, whose text is `code` with line breaks rewritten to U+2028.
    /// That rewrite is 1:1 in UTF-16, so tokens computed from `code` land at the same offsets.
    static func apply(to attributed: NSMutableAttributedString, code: String, language: String?) {
        let profile = SyntaxProfile.profile(for: language)
        let length = attributed.length
        for token in tokenize(code, profile: profile) {
            guard token.range.location >= 0, token.range.location + token.range.length <= length else {
                continue
            }
            attributed.addAttribute(.foregroundColor, value: color(token.type), range: token.range)
        }
    }

    private static func color(_ type: TokenType) -> RTVColor {
        switch type {
        case .comment: return RTVSyntaxColors.comment
        case .string: return RTVSyntaxColors.string
        case .number: return RTVSyntaxColors.number
        case .keyword: return RTVSyntaxColors.keyword
        }
    }
}

extension RichTextSyntaxHighlighter.Token {
    /// The token's UTF-16 range as an NSRange, for NSAttributedString.
    var range: NSRange {
        NSRange(location: utf16Range.lowerBound, length: utf16Range.count)
    }
}
