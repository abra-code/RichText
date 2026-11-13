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

    @Test fun aBlockWithNoLanguageIsNotHighlighted() {
        // A commit message in a fenced block: no string from one apostrophe to the next, no comment at "#"
        val prose = "Linux: applets join the desktop's app list, with their icon\n\nso GNOME's Apps lists it # and 42"
        assertTrue(tokens(prose, null).isEmpty())
        assertTrue(tokens(prose, "").isEmpty())
        for (plain in listOf("text", "txt", "plain", "PlainText", " text ")) {
            assertTrue(plain, tokens("let x = 'a'", plain).isEmpty())
        }
    }

    @Test fun anApostropheInAWordStartsNoStringInAnUnknownLanguage() {
        val code = "the desktop's list, GNOME's apps: 'quoted' and x='y'"
        assertEquals(listOf("'quoted'", "'y'"), tokens(code, "unknownlang").filter { it.type == TokenType.STRING }.map { text(code, it) })
        // A letter with a combining mark, a letter outside the BMP, a superscript digit, a keycap: apostrophes too,
        // as the Swift scanner reads grapheme clusters; after an emoji a "'" opens a string
        val unicode = "cafe\u0301's \uD835\uDC9C's x\u00B2's 1\uFE0F\u20E3's \uD83D\uDE00'y'"
        assertEquals(listOf("'y'"), tokens(unicode, "unknownlang").filter { it.type == TokenType.STRING }.map { text(unicode, it) })
        // A real language keeps its rules: Python's f'...' is a string after a letter, and so is shell's it's
        val python = "s = f'{name}'"
        assertEquals(listOf("'{name}'"), tokens(python, "python").filter { it.type == TokenType.STRING }.map { text(python, it) })
        val shell = "echo it's"
        assertEquals(listOf("'s"), tokens(shell, "sh").filter { it.type == TokenType.STRING }.map { text(shell, it) })
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
