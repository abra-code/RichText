package com.abracode.richtext.rendering

import androidx.compose.foundation.text.appendInlineContent
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.em
import com.abracode.richtext.RichTextURLPolicy
import com.abracode.richtext.model.RichTextInline

// Builds the Compose AnnotatedString for a run of inline nodes - the analog of the Swift
// RichTextAttributedBuilder.renderInlines (base/bold/italic/strike/link/color threaded down the tree). Style
// mapping matches the Swift builder: emphasis = italic, strong = bold, strikethrough = LineThrough, code span =
// monospace + inline-code fill + 0.94em, link = link color + underline gated by RichTextURLPolicy (a disallowed
// scheme renders as plain, non-tappable text, keeping the visible text - exactly like Swift). Inline code font
// size uses `em` so it tracks the surrounding text size (heading vs body), matching the Swift 0.94 mono scale.
//
// Images are a Compose-specific concern (the plan's block-composable renderer, divergence #1, has no single
// text view with attachments): each image node becomes an inline-content placeholder here, and the caller
// (RichText.kt) supplies the actual CachedImage composable via the returned [RichTextInlineResult.images].

/** An inline image discovered while building the string; the caller maps each id to an InlineTextContent. */
data class RichTextInlineImageRef(val id: String, val alt: String, val url: String)

/** A code-span character range (end-exclusive) in the built string, so the caller can draw a rounded pill. */
data class RichTextCodeSpan(val start: Int, val end: Int)

/**
 * The built inline string plus the inline images it references (empty for the common text-only case) and the
 * code-span ranges. Inline code carries no `background` in its span; the renderer paints a rounded pill behind
 * each [codeSpans] range instead (Stage E phase 2), matching the Apple drawn pill.
 */
class RichTextInlineResult(
    val text: AnnotatedString,
    val images: List<RichTextInlineImageRef>,
    val codeSpans: List<RichTextCodeSpan>,
)

// The inherited inline context, mirroring the Swift renderInlines parameters. `color` is the inherited text
// color (body at top level, secondary inside quotes); `link` is the allow-listed URL or null.
private data class InlineContext(
    val bold: Boolean,
    val italic: Boolean,
    val strike: Boolean,
    val link: String?,
    val color: Color,
    val colors: RichTextColors,
)

/**
 * Builds an [RichTextInlineResult] from [nodes]. [baseColor] is the inherited text color; [initialBold] starts
 * the run bold (headings render their inlines bold, per the Swift builder).
 */
fun buildRichInlines(
    nodes: List<RichTextInline>,
    colors: RichTextColors,
    baseColor: Color,
    initialBold: Boolean = false,
): RichTextInlineResult {
    val images = mutableListOf<RichTextInlineImageRef>()
    val codeSpans = mutableListOf<RichTextCodeSpan>()
    val text = buildAnnotatedString {
        appendInlines(nodes, InlineContext(initialBold, italic = false, strike = false, link = null, color = baseColor, colors = colors), images, codeSpans)
    }
    return RichTextInlineResult(text, images, codeSpans)
}

private fun AnnotatedString.Builder.appendInlines(
    nodes: List<RichTextInline>,
    ctx: InlineContext,
    images: MutableList<RichTextInlineImageRef>,
    codeSpans: MutableList<RichTextCodeSpan>,
) {
    for (node in nodes) {
        when (node) {
            is RichTextInline.Text -> appendTextRun(node.value, ctx)
            RichTextInline.LineBreak -> append("\n")   // hard break: a forced line break within the block
            is RichTextInline.Code -> {
                val start = length
                appendCodeRun(node.value, ctx)
                codeSpans.add(RichTextCodeSpan(start, length))
            }
            is RichTextInline.Emphasis -> appendInlines(node.children, ctx.copy(italic = true), images, codeSpans)
            is RichTextInline.Strong -> appendInlines(node.children, ctx.copy(bold = true), images, codeSpans)
            is RichTextInline.Strikethrough -> appendInlines(node.children, ctx.copy(strike = true), images, codeSpans)
            is RichTextInline.Link -> {
                // Gate the tappable target on the allow-list: an allow-listed scheme becomes a real link,
                // otherwise the text renders plain and non-tappable (a javascript:/file: target can never fire).
                if (RichTextURLPolicy.allowedLink(node.url) != null) {
                    withLink(LinkAnnotation.Url(node.url)) {
                        appendInlines(node.text, ctx.copy(link = node.url), images, codeSpans)
                    }
                } else {
                    appendInlines(node.text, ctx, images, codeSpans)
                }
            }
            is RichTextInline.Image -> {
                val id = "img${images.size}"
                images.add(RichTextInlineImageRef(id, node.alt, node.url))
                // Alternate text is what selection-copy / accessibility read for the placeholder glyph.
                appendInlineContent(id, node.alt.ifEmpty { "image" })
            }
        }
    }
}

private fun AnnotatedString.Builder.appendTextRun(s: String, ctx: InlineContext) {
    withStyle(
        SpanStyle(
            color = if (ctx.link != null) ctx.colors.link else ctx.color,
            fontWeight = if (ctx.bold) FontWeight.Bold else null,
            fontStyle = if (ctx.italic) FontStyle.Italic else null,
            textDecoration = decoration(strike = ctx.strike, underline = ctx.link != null),
        ),
    ) { append(s) }
}

private fun AnnotatedString.Builder.appendCodeRun(s: String, ctx: InlineContext) {
    // Inline code: monospace, no flat background (a rounded pill is painted behind the span by the renderer,
    // Stage E phase 2). No underline even inside a link, matching the Swift codeRun. fontWeight is pinned to
    // Normal so a code span inside a heading (whose base style is Bold) renders regular-weight mono like Swift.
    withStyle(
        SpanStyle(
            color = if (ctx.link != null) ctx.colors.link else ctx.color,
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.Normal,
            fontSize = 0.94.em,
            textDecoration = if (ctx.strike) TextDecoration.LineThrough else null,
        ),
    ) { append(s) }
}

private fun decoration(strike: Boolean, underline: Boolean): TextDecoration? = when {
    strike && underline -> TextDecoration.combine(listOf(TextDecoration.LineThrough, TextDecoration.Underline))
    strike -> TextDecoration.LineThrough
    underline -> TextDecoration.Underline
    else -> null
}

/**
 * If [this] paragraph's inlines are a single image (ignoring surrounding blank text and hard breaks), returns
 * that image so the caller can render it as a block image; otherwise null. The plan renders a lone-image
 * paragraph as a block image and mixed images inline (section 4).
 */
fun List<RichTextInline>.soleBlockImage(): RichTextInline.Image? {
    var found: RichTextInline.Image? = null
    for (node in this) {
        when (node) {
            is RichTextInline.Text -> if (node.value.isNotBlank()) return null
            RichTextInline.LineBreak -> {}
            is RichTextInline.Image -> {
                if (found != null) return null
                found = node
            }
            else -> return null
        }
    }
    return found
}
