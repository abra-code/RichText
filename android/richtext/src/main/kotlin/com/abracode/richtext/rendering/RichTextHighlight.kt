package com.abracode.richtext.rendering

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import com.abracode.richtext.search.RichTextMatch
import com.abracode.richtext.search.RichTextRange

// Port of Sources/RichText/Rendering/RichTextHighlight.swift - layer 2 of the find stack: painting ranges.
// `RichTextHighlights` is a value the RichText composable takes (`highlights = ...`); each block composable
// paints the part of it that falls inside its own segment (RichTextRenderedText) as a background span. Apple
// paints draw-only, without touching the text storage; Compose has no draw-only text attribute, so the block's
// AnnotatedString is rebuilt with the spans added (plan divergence #8) - it is memoized on (block, highlights),
// so an unchanged block costs nothing and a query change rebuilds only the blocks it lights.

/**
 * Colors for the highlighted ranges. Translucent, so the text keeps its own color on top and stays readable in a
 * dark scheme where an opaque find-yellow behind white text would not.
 */
data class RichTextHighlightStyle(
    /** Every match. */
    val color: Color,
    /** The one match the reader is on ([RichTextHighlights.current]). */
    val currentColor: Color,
) {
    companion object {
        val Default = RichTextHighlightStyle(
            color = Color(0xFFFFCC00).copy(alpha = 0.35f),
            currentColor = Color(0xFFFF9500).copy(alpha = 0.55f),
        )
    }
}

/** The ranges to paint, in the rendered text (what [com.abracode.richtext.search.RichTextSearch] returns). */
data class RichTextHighlights(
    val ranges: List<RichTextRange>,
    /** Index into [ranges] of the match to paint in [RichTextHighlightStyle.currentColor]; null paints all alike. */
    val current: Int? = null,
    val style: RichTextHighlightStyle = RichTextHighlightStyle.Default,
) {
    val isEmpty: Boolean get() = ranges.isEmpty()

    companion object {
        /** The highlights for a list of matches (the same shape a JVM constructor overload could not carry). */
        fun ofMatches(matches: List<RichTextMatch>, current: Int? = null, style: RichTextHighlightStyle = RichTextHighlightStyle.Default) =
            RichTextHighlights(matches.map { it.range }, current, style)
    }

    /** The current range, if [current] names one. */
    val currentRange: RichTextRange? get() = current?.let { ranges.getOrNull(it) }
}

/** The highlights of ONE segment, in that segment's local offsets (what a block composable paints). */
data class RichTextLocalHighlights(
    val ranges: List<RichTextRange>,
    val current: Int?,
    val style: RichTextHighlightStyle,
) {
    val currentRange: RichTextRange? get() = current?.let { ranges.getOrNull(it) }
}

/** [text] with [highlights] painted as background spans; ranges past the end are clipped, never fatal. */
internal fun AnnotatedString.withHighlights(highlights: RichTextLocalHighlights?): AnnotatedString {
    if (highlights == null || highlights.ranges.isEmpty()) return this
    val source = this
    return buildAnnotatedString {
        append(source)
        highlights.ranges.forEachIndexed { index, range ->
            val start = range.start.coerceIn(0, source.length)
            val end = range.end.coerceIn(0, source.length)
            if (end <= start) return@forEachIndexed
            val color = if (index == highlights.current) highlights.style.currentColor else highlights.style.color
            addStyle(SpanStyle(background = color), start, end)
        }
    }
}
