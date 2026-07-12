package com.abracode.richtext.rendering

import com.abracode.richtext.isMarkdownNumber
import com.abracode.richtext.trimMarkdownWhitespace

// A small, dependency-free syntax highlighter for fenced code blocks. It is a GENERIC lexer - it recognizes
// comments, strings, numbers, and a per-language keyword set - rather than a full grammar, which is enough to
// make code read like code without pulling in a parser per language. The fenced block's info string selects a
// language profile (comment / string styles + keywords); an unknown language falls back to a permissive
// default. Output is engine-agnostic token runs (offset + length + type); the Compose renderer resolves each
// type to a theme-adaptive color at draw time (Stage D). A 1:1 port of the tokenizer and profiles in
// Sources/RichText/Rendering/RichTextSyntaxHighlighter.swift.

object RichTextSyntaxHighlighter {

    enum class TokenType { COMMENT, STRING, NUMBER, KEYWORD }

    /** A colored run: `[start, start + length)` are UTF-16 offsets into the original code string. */
    data class Token(val start: Int, val length: Int, val type: TokenType) {
        val end: Int get() = start + length
    }

    /** Tokenizes `code` under an explicit profile. */
    fun tokenize(code: String, profile: SyntaxProfile): List<Token> {
        val scanner = Scanner(code)
        val tokens = mutableListOf<Token>()

        while (true) {
            val c = scanner.peek() ?: break

            // Block comment (may span lines; unterminated runs to end - streaming-safe).
            val block = profile.blockComment
            if (block != null && scanner.matches(block.open)) {
                val start = scanner.location
                scanner.advance(block.open.length)
                while (!scanner.isAtEnd && !scanner.matches(block.close)) {
                    scanner.advance()
                }
                if (scanner.matches(block.close)) {
                    scanner.advance(block.close.length)
                }
                tokens.add(Token(start, scanner.location - start, TokenType.COMMENT))
                continue
            }

            // Line comment (to end of line).
            val marker = profile.lineComments.firstOrNull { scanner.matches(it) }
            if (marker != null) {
                val start = scanner.location
                scanner.advance(marker.length)
                while (true) {
                    val ch = scanner.peek() ?: break
                    if (ch == '\n') break
                    scanner.advance()
                }
                tokens.add(Token(start, scanner.location - start, TokenType.COMMENT))
                continue
            }

            // String literal (stops at the matching unescaped delimiter, or end of line - streaming-safe).
            if (c in profile.stringDelimiters) {
                val start = scanner.location
                scanner.advance()
                while (true) {
                    val ch = scanner.peek() ?: break
                    if (ch == c || ch == '\n') break
                    if (ch == '\\') scanner.advance()   // skip the escaped character
                    scanner.advance()
                }
                if (scanner.peek() == c) {
                    scanner.advance()
                }
                tokens.add(Token(start, scanner.location - start, TokenType.STRING))
                continue
            }

            // Number literal. Starts on a digit only (a leading-dot form like ".5" is rare and would mis-lex the
            // trailing "." of a range operator such as "0...5"); "0.5" still works because it starts on the digit.
            if (c.isMarkdownNumber()) {
                val start = scanner.location
                scanNumber(scanner)
                tokens.add(Token(start, scanner.location - start, TokenType.NUMBER))
                continue
            }

            // Identifier - colored only if it is a keyword.
            if (c.isLetter() || c == '_') {
                val start = scanner.location
                val word = StringBuilder()
                while (true) {
                    val ch = scanner.peek() ?: break
                    if (ch.isLetter() || ch.isMarkdownNumber() || ch == '_') {
                        word.append(ch)
                        scanner.advance()
                    } else {
                        break
                    }
                }
                if (word.toString() in profile.keywords) {
                    tokens.add(Token(start, scanner.location - start, TokenType.KEYWORD))
                }
                continue
            }

            scanner.advance()
        }
        return tokens
    }

    private fun scanNumber(scanner: Scanner) {
        // Hex / binary / octal prefix.
        if (scanner.peek() == '0') {
            val next = scanner.peek(1)
            if (next != null && next in "xXbBoO") {
                scanner.advance(2)
                while (true) {
                    val ch = scanner.peek() ?: break
                    if (ch.isAsciiHexDigit() || ch == '_') scanner.advance() else break
                }
                return
            }
        }
        while (true) {
            val ch = scanner.peek() ?: break
            if (ch.isMarkdownNumber() || ch == '_') scanner.advance() else break
        }
        if (scanner.peek() == '.') {
            val next = scanner.peek(1)
            if (next != null && next.isMarkdownNumber()) {
                scanner.advance()
                while (true) {
                    val ch = scanner.peek() ?: break
                    if (ch.isMarkdownNumber() || ch == '_') scanner.advance() else break
                }
            }
        }
        val e = scanner.peek()
        if (e == 'e' || e == 'E') {
            var lookahead = 1
            val sign = scanner.peek(lookahead)
            if (sign == '+' || sign == '-') lookahead++
            val digit = scanner.peek(lookahead)
            if (digit != null && digit.isMarkdownNumber()) {
                scanner.advance(lookahead)
                while (true) {
                    val ch = scanner.peek() ?: break
                    if (ch.isMarkdownNumber() || ch == '_') scanner.advance() else break
                }
            }
        }
    }

    private fun Char.isAsciiHexDigit(): Boolean = this in '0'..'9' || this in 'a'..'f' || this in 'A'..'F'
}

// A character scanner over UTF-16 code units, so `location` is a valid offset into the original string. (The
// Swift scanner iterates grapheme clusters while tracking a separate UTF-16 offset; because every token
// delimiter is ASCII, code-unit iteration yields the same offsets and token boundaries for real code.)
private class Scanner(private val text: String) {
    var location = 0
        private set

    val isAtEnd: Boolean get() = location >= text.length

    fun peek(ahead: Int = 0): Char? {
        val position = location + ahead
        return if (position < text.length) text[position] else null
    }

    fun advance(count: Int = 1) {
        var remaining = count
        while (remaining > 0 && location < text.length) {
            location++
            remaining--
        }
    }

    fun matches(token: String): Boolean {
        if (location + token.length > text.length) return false
        for (k in token.indices) {
            if (text[location + k] != token[k]) return false
        }
        return true
    }
}

// MARK: - Language profiles

class SyntaxProfile(
    val lineComments: List<String>,
    val blockComment: BlockComment?,
    val stringDelimiters: Set<Char>,
    val keywords: Set<String>,
) {
    data class BlockComment(val open: String, val close: String)

    companion object {
        fun profile(language: String?): SyntaxProfile {
            val key = (language ?: "").lowercase().trimMarkdownWhitespace()
            return when (key) {
                "swift" ->
                    SyntaxProfile(listOf("//"), BlockComment("/*", "*/"), setOf('"'), swiftKeywords)
                "c", "cpp", "c++", "cxx", "objc", "objective-c", "m", "mm", "h", "hpp" ->
                    SyntaxProfile(listOf("//"), BlockComment("/*", "*/"), setOf('"', '\''), cKeywords)
                "js", "javascript", "jsx", "ts", "typescript", "tsx" ->
                    SyntaxProfile(listOf("//"), BlockComment("/*", "*/"), setOf('"', '\'', '`'), jsKeywords)
                "python", "py" ->
                    SyntaxProfile(listOf("#"), null, setOf('"', '\''), pythonKeywords)
                "ruby", "rb" ->
                    SyntaxProfile(listOf("#"), null, setOf('"', '\''), rubyKeywords)
                "bash", "sh", "shell", "zsh", "console" ->
                    SyntaxProfile(listOf("#"), null, setOf('"', '\''), shellKeywords)
                "go", "golang" ->
                    SyntaxProfile(listOf("//"), BlockComment("/*", "*/"), setOf('"', '`'), goKeywords)
                "rust", "rs" ->
                    SyntaxProfile(listOf("//"), BlockComment("/*", "*/"), setOf('"'), rustKeywords)
                "java", "kotlin", "kt" ->
                    SyntaxProfile(listOf("//"), BlockComment("/*", "*/"), setOf('"', '\''), javaKeywords)
                "json" ->
                    SyntaxProfile(emptyList(), null, setOf('"'), setOf("true", "false", "null"))
                else ->
                    SyntaxProfile(listOf("//", "#"), BlockComment("/*", "*/"), setOf('"', '\'', '`'), defaultKeywords)
            }
        }

        private val swiftKeywords = setOf(
            "associatedtype", "class", "deinit", "enum", "extension", "func", "import", "init", "inout", "let",
            "operator", "private", "fileprivate", "internal", "public", "open", "protocol", "static", "struct",
            "subscript", "typealias", "var", "actor", "async", "await", "break", "case", "continue", "default",
            "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch",
            "where", "while", "as", "is", "nil", "self", "Self", "super", "throw", "throws", "rethrows", "try",
            "true", "false", "some", "any", "lazy", "weak", "unowned", "mutating", "nonmutating", "override",
            "final", "convenience", "required", "indirect",
        )

        private val cKeywords = setOf(
            "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum",
            "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "return", "short",
            "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile",
            "while", "bool", "class", "namespace", "template", "public", "private", "protected", "virtual",
            "new", "delete", "this", "nullptr", "true", "false", "using", "typename",
        )

        private val jsKeywords = setOf(
            "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do",
            "else", "export", "extends", "finally", "for", "function", "if", "import", "in", "instanceof",
            "let", "new", "return", "super", "switch", "this", "throw", "try", "typeof", "var", "void", "while",
            "with", "yield", "async", "await", "of", "true", "false", "null", "undefined", "interface", "type",
            "enum", "implements", "public", "private", "protected", "readonly", "as",
        )

        private val pythonKeywords = setOf(
            "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue",
            "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in",
            "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield",
            "self", "print",
        )

        private val rubyKeywords = setOf(
            "begin", "break", "case", "class", "def", "do", "else", "elsif", "end", "ensure", "false", "for",
            "if", "in", "module", "next", "nil", "not", "or", "and", "redo", "rescue", "retry", "return",
            "self", "super", "then", "true", "unless", "until", "when", "while", "yield", "require", "attr_accessor",
        )

        private val shellKeywords = setOf(
            "if", "then", "else", "elif", "fi", "case", "esac", "for", "while", "until", "do", "done", "in",
            "function", "select", "time", "return", "export", "local", "readonly", "echo", "cd", "set", "unset",
            "source", "alias",
        )

        private val goKeywords = setOf(
            "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for",
            "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select",
            "struct", "switch", "type", "var", "nil", "true", "false", "string", "int", "bool", "error",
        )

        private val rustKeywords = setOf(
            "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern",
            "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub",
            "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe",
            "use", "where", "while",
        )

        private val javaKeywords = setOf(
            "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const",
            "continue", "default", "do", "double", "else", "enum", "extends", "final", "finally", "float",
            "for", "if", "implements", "import", "instanceof", "int", "interface", "long", "native", "new",
            "package", "private", "protected", "public", "return", "short", "static", "super", "switch",
            "synchronized", "this", "throw", "throws", "transient", "try", "void", "volatile", "while", "var",
            "val", "fun", "true", "false", "null", "object", "when",
        )

        private val defaultKeywords = setOf(
            "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return",
            "function", "func", "def", "class", "struct", "enum", "const", "let", "var", "import", "export",
            "public", "private", "static", "new", "try", "catch", "throw", "true", "false", "null", "nil",
            "void", "int", "string", "bool",
        )
    }
}
