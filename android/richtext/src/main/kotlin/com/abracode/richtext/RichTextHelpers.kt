package com.abracode.richtext

// Small text helpers shared by the parser and the syntax highlighter, ported to match the Swift Foundation
// semantics the reference relies on. Kept in one place so the whole pure-logic layer trims and classifies
// characters identically.

/**
 * True for the characters in Swift's `CharacterSet.whitespaces`: CHARACTER TABULATION (U+0009) plus every
 * code point in Unicode General Category Zs (space separators). Deliberately NOT newlines - the reference
 * splits on newlines first, then trims lines with `.whitespaces`, so this must exclude line breaks (unlike
 * Kotlin's [Char.isWhitespace], which would also strip U+2028 / newlines).
 */
internal fun Char.isMarkdownWhitespace(): Boolean =
    this == '\t' || Character.getType(this) == Character.SPACE_SEPARATOR.toInt()

/** Trims leading/trailing [isMarkdownWhitespace] characters - the port of `trimmingCharacters(in: .whitespaces)`. */
internal fun String.trimMarkdownWhitespace(): String {
    var start = 0
    var end = length
    while (start < end && this[start].isMarkdownWhitespace()) start++
    while (end > start && this[end - 1].isMarkdownWhitespace()) end--
    return substring(start, end)
}

/**
 * The port of Swift's `Character.isNumber`: any code point in Unicode General Categories Nd (decimal digit),
 * Nl (letter number) or No (other number). Broader than Kotlin's [Char.isDigit] (Nd only), which matters for
 * exotic numerals in list markers and code so classification matches the reference.
 */
internal fun Char.isMarkdownNumber(): Boolean {
    val type = Character.getType(this)
    return type == Character.DECIMAL_DIGIT_NUMBER.toInt() ||
        type == Character.LETTER_NUMBER.toInt() ||
        type == Character.OTHER_NUMBER.toInt()
}
