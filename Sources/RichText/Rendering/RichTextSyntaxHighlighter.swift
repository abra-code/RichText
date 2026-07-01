// Sources/RichText/Rendering/RichTextSyntaxHighlighter.swift
//
// A small, dependency-free syntax highlighter for fenced code blocks (design doc P5). It is a GENERIC
// lexer - it recognizes comments, strings, numbers, and a per-language keyword set - rather than a full
// grammar, which is enough to make code read like code without pulling in a parser per language. The
// fenced block's info string selects a language profile (comment / string styles + keywords); an unknown
// language falls back to a permissive default. Output is plain `.foregroundColor` runs, so it is engine-
// agnostic: both the TextKit 1 and TextKit 2 backends render it for free, behind the same code-block card.
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

enum RichTextSyntaxHighlighter {
    enum TokenType {
        case comment
        case string
        case number
        case keyword
    }

    struct Token {
        let range: NSRange      // UTF-16 offsets into the original code string
        let type: TokenType
    }

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

    // MARK: - Lexer

    static func tokenize(_ code: String, profile: SyntaxProfile) -> [Token] {
        let scanner = Scanner(code)
        var tokens: [Token] = []

        while let c = scanner.peek() {
            // Block comment (may span lines; unterminated runs to end - streaming-safe).
            if let block = profile.blockComment, scanner.matches(block.open) {
                let start = scanner.location
                scanner.advance(block.open.count)
                while !scanner.isAtEnd, !scanner.matches(block.close) {
                    scanner.advance()
                }
                if scanner.matches(block.close) {
                    scanner.advance(block.close.count)
                }
                tokens.append(Token(range: scanner.range(from: start), type: .comment))
                continue
            }

            // Line comment (to end of line).
            if let marker = profile.lineComments.first(where: { scanner.matches($0) }) {
                let start = scanner.location
                scanner.advance(marker.count)
                while let ch = scanner.peek(), ch != "\n" {
                    scanner.advance()
                }
                tokens.append(Token(range: scanner.range(from: start), type: .comment))
                continue
            }

            // String literal (stops at the matching unescaped delimiter, or end of line - streaming-safe).
            if profile.stringDelimiters.contains(c) {
                let start = scanner.location
                scanner.advance()
                while let ch = scanner.peek(), ch != c, ch != "\n" {
                    if ch == "\\" {
                        scanner.advance()       // skip the escaped character
                    }
                    scanner.advance()
                }
                if scanner.peek() == c {
                    scanner.advance()
                }
                tokens.append(Token(range: scanner.range(from: start), type: .string))
                continue
            }

            // Number literal. Starts on a digit only (a leading-dot form like ".5" is rare and would
            // mis-lex the trailing "." of a range operator such as "0...5"); "0.5" still works because it
            // starts on the digit and the fraction is consumed below.
            if c.isNumber {
                let start = scanner.location
                scanNumber(scanner)
                tokens.append(Token(range: scanner.range(from: start), type: .number))
                continue
            }

            // Identifier - colored only if it is a keyword.
            if c.isLetter || c == "_" {
                let start = scanner.location
                var word = ""
                while let ch = scanner.peek(), ch.isLetter || ch.isNumber || ch == "_" {
                    word.append(ch)
                    scanner.advance()
                }
                if profile.keywords.contains(word) {
                    tokens.append(Token(range: scanner.range(from: start), type: .keyword))
                }
                continue
            }

            scanner.advance()
        }
        return tokens
    }

    private static func scanNumber(_ scanner: Scanner) {
        // Hex / binary / octal prefix.
        if scanner.peek() == "0", let next = scanner.peek(1), "xXbBoO".contains(next) {
            scanner.advance(2)
            while let ch = scanner.peek(), ch.isHexDigit || ch == "_" {
                scanner.advance()
            }
            return
        }
        while let ch = scanner.peek(), ch.isNumber || ch == "_" {
            scanner.advance()
        }
        if scanner.peek() == ".", let next = scanner.peek(1), next.isNumber {
            scanner.advance()
            while let ch = scanner.peek(), ch.isNumber || ch == "_" {
                scanner.advance()
            }
        }
        if let e = scanner.peek(), e == "e" || e == "E" {
            var lookahead = 1
            if let sign = scanner.peek(lookahead), sign == "+" || sign == "-" {
                lookahead += 1
            }
            if let digit = scanner.peek(lookahead), digit.isNumber {
                scanner.advance(lookahead)
                while let ch = scanner.peek(), ch.isNumber || ch == "_" {
                    scanner.advance()
                }
            }
        }
    }
}

// A character scanner that tracks the UTF-16 offset alongside the character index, so emitted ranges are
// valid NSRanges into the original string.
private final class Scanner {
    private let chars: [Character]
    private var index = 0
    private(set) var location = 0   // UTF-16 offset of chars[index]

    init(_ string: String) {
        chars = Array(string)
    }

    var isAtEnd: Bool {
        return index >= chars.count
    }

    func peek(_ ahead: Int = 0) -> Character? {
        let position = index + ahead
        return position < chars.count ? chars[position] : nil
    }

    func advance(_ count: Int = 1) {
        for _ in 0..<count {
            guard index < chars.count else {
                return
            }
            location += String(chars[index]).utf16.count
            index += 1
        }
    }

    func matches(_ token: String) -> Bool {
        let tokenChars = Array(token)
        guard index + tokenChars.count <= chars.count else {
            return false
        }
        for (offset, ch) in tokenChars.enumerated() where chars[index + offset] != ch {
            return false
        }
        return true
    }

    func range(from start: Int) -> NSRange {
        return NSRange(location: start, length: location - start)
    }
}

// MARK: - Language profiles

struct SyntaxProfile {
    var lineComments: [String]
    var blockComment: (open: String, close: String)?
    var stringDelimiters: Set<Character>
    var keywords: Set<String>

    static func profile(for language: String?) -> SyntaxProfile {
        let key = (language ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        switch key {
        case "swift":
            return SyntaxProfile(lineComments: ["//"], blockComment: ("/*", "*/"), stringDelimiters: ["\""], keywords: swiftKeywords)
        case "c", "cpp", "c++", "cxx", "objc", "objective-c", "m", "mm", "h", "hpp":
            return SyntaxProfile(lineComments: ["//"], blockComment: ("/*", "*/"), stringDelimiters: ["\"", "'"], keywords: cKeywords)
        case "js", "javascript", "jsx", "ts", "typescript", "tsx":
            return SyntaxProfile(lineComments: ["//"], blockComment: ("/*", "*/"), stringDelimiters: ["\"", "'", "`"], keywords: jsKeywords)
        case "python", "py":
            return SyntaxProfile(lineComments: ["#"], blockComment: nil, stringDelimiters: ["\"", "'"], keywords: pythonKeywords)
        case "ruby", "rb":
            return SyntaxProfile(lineComments: ["#"], blockComment: nil, stringDelimiters: ["\"", "'"], keywords: rubyKeywords)
        case "bash", "sh", "shell", "zsh", "console":
            return SyntaxProfile(lineComments: ["#"], blockComment: nil, stringDelimiters: ["\"", "'"], keywords: shellKeywords)
        case "go", "golang":
            return SyntaxProfile(lineComments: ["//"], blockComment: ("/*", "*/"), stringDelimiters: ["\"", "`"], keywords: goKeywords)
        case "rust", "rs":
            return SyntaxProfile(lineComments: ["//"], blockComment: ("/*", "*/"), stringDelimiters: ["\""], keywords: rustKeywords)
        case "java", "kotlin", "kt":
            return SyntaxProfile(lineComments: ["//"], blockComment: ("/*", "*/"), stringDelimiters: ["\"", "'"], keywords: javaKeywords)
        case "json":
            return SyntaxProfile(lineComments: [], blockComment: nil, stringDelimiters: ["\""], keywords: ["true", "false", "null"])
        default:
            return SyntaxProfile(lineComments: ["//", "#"], blockComment: ("/*", "*/"), stringDelimiters: ["\"", "'", "`"], keywords: defaultKeywords)
        }
    }

    private static let swiftKeywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "func", "import", "init", "inout", "let",
        "operator", "private", "fileprivate", "internal", "public", "open", "protocol", "static", "struct",
        "subscript", "typealias", "var", "actor", "async", "await", "break", "case", "continue", "default",
        "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch",
        "where", "while", "as", "is", "nil", "self", "Self", "super", "throw", "throws", "rethrows", "try",
        "true", "false", "some", "any", "lazy", "weak", "unowned", "mutating", "nonmutating", "override",
        "final", "convenience", "required", "indirect",
    ]

    private static let cKeywords: Set<String> = [
        "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum",
        "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "return", "short",
        "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile",
        "while", "bool", "class", "namespace", "template", "public", "private", "protected", "virtual",
        "new", "delete", "this", "nullptr", "true", "false", "using", "typename",
    ]

    private static let jsKeywords: Set<String> = [
        "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do",
        "else", "export", "extends", "finally", "for", "function", "if", "import", "in", "instanceof",
        "let", "new", "return", "super", "switch", "this", "throw", "try", "typeof", "var", "void", "while",
        "with", "yield", "async", "await", "of", "true", "false", "null", "undefined", "interface", "type",
        "enum", "implements", "public", "private", "protected", "readonly", "as",
    ]

    private static let pythonKeywords: Set<String> = [
        "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue",
        "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in",
        "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield",
        "self", "print",
    ]

    private static let rubyKeywords: Set<String> = [
        "begin", "break", "case", "class", "def", "do", "else", "elsif", "end", "ensure", "false", "for",
        "if", "in", "module", "next", "nil", "not", "or", "and", "redo", "rescue", "retry", "return",
        "self", "super", "then", "true", "unless", "until", "when", "while", "yield", "require", "attr_accessor",
    ]

    private static let shellKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "case", "esac", "for", "while", "until", "do", "done", "in",
        "function", "select", "time", "return", "export", "local", "readonly", "echo", "cd", "set", "unset",
        "source", "alias",
    ]

    private static let goKeywords: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for",
        "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select",
        "struct", "switch", "type", "var", "nil", "true", "false", "string", "int", "bool", "error",
    ]

    private static let rustKeywords: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern",
        "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub",
        "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe",
        "use", "where", "while",
    ]

    private static let javaKeywords: Set<String> = [
        "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const",
        "continue", "default", "do", "double", "else", "enum", "extends", "final", "finally", "float",
        "for", "if", "implements", "import", "instanceof", "int", "interface", "long", "native", "new",
        "package", "private", "protected", "public", "return", "short", "static", "super", "switch",
        "synchronized", "this", "throw", "throws", "transient", "try", "void", "volatile", "while", "var",
        "val", "fun", "true", "false", "null", "object", "when",
    ]

    private static let defaultKeywords: Set<String> = [
        "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return",
        "function", "func", "def", "class", "struct", "enum", "const", "let", "var", "import", "export",
        "public", "private", "static", "new", "try", "catch", "throw", "true", "false", "null", "nil",
        "void", "int", "string", "bool",
    ]
}
