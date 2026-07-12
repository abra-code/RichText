package com.abracode.richtext

import com.abracode.richtext.rendering.RichTextSyntaxHighlighter
import com.abracode.richtext.rendering.RichTextSyntaxHighlighter.Token
import com.abracode.richtext.rendering.RichTextSyntaxHighlighter.TokenType
import com.abracode.richtext.rendering.SyntaxProfile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

// Port of the tokenizer cases from Tests/RichTextTests/RichTextSyntaxHighlighterTests.swift. The two cases that
// assert colors applied through the attributed-string builder belong to the Compose renderer (Stage D).
class RichTextSyntaxHighlighterTest {

    private fun tokens(code: String, language: String?): List<Token> =
        RichTextSyntaxHighlighter.tokenize(code, SyntaxProfile.profile(language))

    private fun text(code: String, token: Token): String = code.substring(token.start, token.end)

    @Test fun keywordStringNumberComment() {
        val code = "// hi\nlet x = 42\nlet s = \"hello\""
        val found = tokens(code, "swift")
        assertTrue(found.any { it.type == TokenType.COMMENT && text(code, it) == "// hi" })
        assertTrue(found.any { it.type == TokenType.KEYWORD && text(code, it) == "let" })
        assertTrue(found.any { it.type == TokenType.NUMBER && text(code, it) == "42" })
        assertTrue(found.any { it.type == TokenType.STRING && text(code, it) == "\"hello\"" })
    }

    @Test fun stringEscapeDoesNotEndEarly() {
        val code = "\"a\\\"b\""              // the literal "a\"b"
        val strings = tokens(code, "swift").filter { it.type == TokenType.STRING }
        assertEquals(1, strings.size)
        assertEquals(code, text(code, strings[0]))
    }

    @Test fun blockCommentSpansLines() {
        val code = "/* a\n b */ let"
        val found = tokens(code, "swift")
        assertTrue(found.any { it.type == TokenType.COMMENT && text(code, it) == "/* a\n b */" })
        assertTrue(found.any { it.type == TokenType.KEYWORD && text(code, it) == "let" })
    }

    @Test fun commentStyleIsLanguageSpecific() {
        val code = "# c\nx = 1"
        assertTrue(tokens(code, "python").any { it.type == TokenType.COMMENT && text(code, it) == "# c" })
        // '#' is not a comment in Swift (which uses //), so the Swift profile finds no comment here.
        assertFalse(tokens(code, "swift").any { it.type == TokenType.COMMENT })
    }

    @Test fun numberDoesNotSwallowRangeOperator() {
        // "0...5" must not be lexed as one number; only "0" and "5" are numbers.
        val code = "for i in 0...5 {}"
        val numbers = tokens(code, "swift").filter { it.type == TokenType.NUMBER }.map { text(code, it) }
        assertEquals(listOf("0", "5"), numbers)
    }
}
