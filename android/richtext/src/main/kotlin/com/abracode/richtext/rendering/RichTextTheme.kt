package com.abracode.richtext.rendering

/**
 * Rendering metrics and options for [RichText]. Mirrors the theme metrics in the Swift `RichTextAttributes`
 * (`RTVMetrics`) plus the ActionUI element's tunables. Colors are NOT here: they are semantic and resolve from
 * the Material color scheme at render time (see the Compose renderer in Stage D), matching the Apple side where
 * colors are AppKit/UIKit semantic roles rather than caller-supplied values.
 *
 * Metric defaults match the Swift defaults. Sizes are in sp (fonts) / dp (spacing and radii); [baseFontSize]
 * left null uses the platform body size so the OS font-scale setting applies - the Dynamic Type analog.
 */
data class RichTextTheme(
    /** Base body font size in sp; null uses the platform body text size (user font scaling then applies). */
    val baseFontSize: Float? = null,
    /** Leading indent per nesting level for lists and block quotes, in dp. */
    val indentStep: Float = 22f,
    /** Vertical spacing between top-level blocks and between loose-list items, in dp. */
    val blockSpacing: Float = 9f,
    /** Vertical spacing between tight-list items, in dp. */
    val listSpacing: Float = 3f,
    /** Corner radius of code-block cards, in dp. */
    val codeCornerRadius: Float = 6f,
    /** Inset applied inside table cells, in dp. */
    val cellPadding: Float = 6f,
    /** When false, code blocks render in a single body color instead of tokenized colors. */
    val syntaxHighlighting: Boolean = true,
) {
    companion object {
        val Default = RichTextTheme()
    }
}
