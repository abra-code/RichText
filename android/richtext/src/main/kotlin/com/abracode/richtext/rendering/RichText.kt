package com.abracode.richtext.rendering

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import com.abracode.richtext.find.RichTextFindController
import com.abracode.richtext.search.RichTextRange
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.abracode.asyncimagecache.CachedImage
import com.abracode.asyncimagecache.ContentMode
import com.abracode.asyncimagecache.ImageStore
import com.abracode.richtext.RichTextURLPolicy
import com.abracode.richtext.model.RichTextBlock
import com.abracode.richtext.model.RichTextDocument
import com.abracode.richtext.model.RichTextInline
import androidx.compose.ui.text.Placeholder
import androidx.compose.ui.text.PlaceholderVerticalAlign

// The Compose renderer - the platform half of the port (Sources/RichText/Rendering is the visual spec). Unlike
// Apple, which renders the whole document into ONE text view with custom TextKit decoration drawing, this is a
// Column of per-block composables inside one SelectionContainer (plan divergence #1); the Swift decoration
// constants (card radius, quote-bar width, grid, insets) are reproduced per block. Metric defaults and the
// semantic color roles match the Swift side (RichTextTheme / RTVColors).

/**
 * Renders a parsed [document] with the given [theme].
 *
 * Find (the port of RichText.findHighlights / RichText.find): [highlights] paints ranges of the rendered text
 * ([RichTextRenderedText]) behind the words, the current one in its own color, and [onCurrentMatchBounds] gets the
 * current match's bounds in WINDOW coordinates once laid out (null when there is none) so a host scroller can
 * bring it into view. [find] does both for a [RichTextFindController] and keeps it bound to this document's
 * rendered text; explicit [highlights] win over the controller's.
 */
@Composable
fun RichText(
    document: RichTextDocument,
    theme: RichTextTheme = RichTextTheme.Default,
    modifier: Modifier = Modifier,
    highlights: RichTextHighlights? = null,
    onCurrentMatchBounds: ((Rect?) -> Unit)? = null,
    find: RichTextFindController? = null,
) {
    val colors = rememberRichTextColors()
    val bodySize = theme.baseFontSize?.sp ?: 16.sp
    // The rendered-text walk duplicates the block composables' inline builds, so it runs only for a document
    // that is being searched; the segment arithmetic below needs just the (cheap) per-block counts.
    val searching = find != null || highlights != null
    val layout = remember(document, searching) { if (searching) RichTextRenderedText.layout(document) else RichTextRenderedText.Empty }
    if (find != null) {
        LaunchedEffect(find, layout.text) { find.bind(layout.text) }
    }
    val effective = highlights ?: find?.highlights?.takeIf { !it.isEmpty }
    val controllerReport: ((Rect?) -> Unit)? = remember(find) { find?.let { controller -> { rect: Rect? -> controller.currentMatchBounds = rect } } }
    val report: ((Rect?) -> Unit)? = onCurrentMatchBounds ?: controllerReport
    // No current match: say so once, so a scroller does not keep a stale frame.
    LaunchedEffect(effective?.currentRange, report) {
        if (effective?.currentRange == null) report?.invoke(null)
    }
    val scope = remember(theme, colors, bodySize, layout, effective, report) {
        RichTextScope(theme, colors, bodySize, layout, effective, report)
    }
    SelectionContainer(modifier) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(theme.blockSpacing.dp),
        ) {
            var segmentBase = 0
            for (block in document.blocks) {
                BlockView(block, colors.body, scope, segmentBase)
                segmentBase += RichTextRenderedText.segmentCount(block)
            }
        }
    }
}

/**
 * Parses [markdown] and renders it. The parse is memoized on the string so streaming re-renders (the chat use
 * case) only re-parse when the text actually changes; the parser's totality makes re-parsing partial input safe.
 */
@Composable
fun RichText(
    markdown: String,
    theme: RichTextTheme = RichTextTheme.Default,
    modifier: Modifier = Modifier,
    highlights: RichTextHighlights? = null,
    onCurrentMatchBounds: ((Rect?) -> Unit)? = null,
    find: RichTextFindController? = null,
) {
    val document = remember(markdown) { RichTextDocument.parse(markdown) }
    RichText(document, theme, modifier, highlights, onCurrentMatchBounds, find)
}

// Immutable render context threaded through the block composables (Compose-resolved theme + colors + body size),
// plus the find state: the rendered-text layout the segment indices refer to, the highlights to paint, and where
// to report the current match's bounds.
internal class RichTextScope(
    val theme: RichTextTheme,
    val colors: RichTextColors,
    val bodySize: TextUnit,
    val layout: RichTextRenderedText.Layout,
    val highlights: RichTextHighlights?,
    val onCurrentMatchBounds: ((Rect?) -> Unit)?,
) {
    /** The highlights of segment [index], local to it; null when nothing lights it. */
    fun local(index: Int): RichTextLocalHighlights? = layout.localHighlights(index, highlights)
}

// Image caps mirroring Swift's RichTextImageLoading.defaultMaxWidth (320): a block image displays at most 320dp
// wide and its variant is decoded/cached at most 320px wide (Swift uses 320 as both the point display cap and
// the 1:1 pixel decode cap, an OOM / decompression-bomb defense). Inline images reserve a modest 160dp box.
private const val BLOCK_IMAGE_MAX_WIDTH_DP = 320f
private const val IMAGE_DECODE_MAX_PX = 320f
private const val INLINE_IMAGE_WIDTH_DP = 160f

internal object RichTextMetrics {
    const val MONO_SCALE = 0.94f

    // Heading size multipliers relative to body, from RTVFonts.heading's iOS text styles at the default content
    // size (title1 28 / title2 22 / title3 20 / headline 17 / subheadline 15, vs body 17). Headings are bold.
    fun headingMultiplier(level: Int): Float = when (level) {
        1 -> 28f / 17f
        2 -> 22f / 17f
        3 -> 20f / 17f
        4 -> 1f
        else -> 15f / 17f
    }
}

// [segmentBase] is the index of this block's first segment in the rendered text (RichTextRenderedText); a block
// with children hands each child its own base, in the same draw order the layout walk uses.
@Composable
internal fun BlockView(block: RichTextBlock, color: Color, scope: RichTextScope, segmentBase: Int) {
    when (block) {
        is RichTextBlock.Heading -> HeadingView(block, color, scope, segmentBase)
        is RichTextBlock.Paragraph -> ParagraphView(block.inlines, color, scope, segmentBase)
        is RichTextBlock.CodeBlock -> CodeBlockView(block, scope, segmentBase)
        is RichTextBlock.BlockQuote -> BlockQuoteView(block, scope, segmentBase)
        is RichTextBlock.ListBlock -> ListView(block, color, scope, segmentBase)
        RichTextBlock.ThematicBreak -> ThematicBreakView(scope)
        is RichTextBlock.Table -> RichTextTableView(block, color, scope, segmentBase)
    }
}

@Composable
private fun HeadingView(block: RichTextBlock.Heading, color: Color, scope: RichTextScope, segmentIndex: Int) {
    val size = scope.bodySize * RichTextMetrics.headingMultiplier(block.level)
    val local = scope.local(segmentIndex)
    // Memoize the AnnotatedString build so streaming re-renders (20 Hz) only rebuild when this block's content,
    // the resolved colors or its find highlights actually change, not on every recomposition.
    val result = remember(block.inlines, color, scope.colors, local) {
        buildRichInlines(block.inlines, scope.colors, baseColor = color, initialBold = true).withHighlights(local)
    }
    RichInlineText(
        result = result,
        scope = scope,
        style = TextStyle(fontSize = size, fontWeight = FontWeight.Bold, color = color),
        modifier = Modifier.fillMaxWidth().semantics { heading() },
        currentMatch = local?.currentRange,
    )
}

@Composable
private fun ParagraphView(inlines: List<RichTextInline>, color: Color, scope: RichTextScope, segmentIndex: Int) {
    // A paragraph that is just an image renders as a block image; otherwise as text (with any inline images).
    val soleImage = inlines.soleBlockImage()
    if (soleImage != null) {
        BlockImageView(soleImage, scope)
        return
    }
    val local = scope.local(segmentIndex)
    val result = remember(inlines, color, scope.colors, local) {
        buildRichInlines(inlines, scope.colors, baseColor = color).withHighlights(local)
    }
    RichInlineText(
        result = result,
        scope = scope,
        style = TextStyle(fontSize = scope.bodySize, color = color),
        modifier = Modifier.fillMaxWidth(),
        currentMatch = local?.currentRange,
    )
}

@Composable
private fun CodeBlockView(block: RichTextBlock.CodeBlock, scope: RichTextScope, segmentIndex: Int) {
    val local = scope.local(segmentIndex)
    val annotated = remember(block.code, block.language, scope.theme.syntaxHighlighting, scope.colors, local) {
        buildCodeAnnotated(block.code, block.language, scope.theme.syntaxHighlighting, scope.colors).withHighlights(local)
    }
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .background(scope.colors.codeFill, RoundedCornerShape(scope.theme.codeCornerRadius.dp)),
    ) {
        // Long lines scroll inside the card instead of wrapping, matching Apple's non-wrapping code.
        Box(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 10.dp, vertical = 6.dp)) {
            val bounds = rememberMatchBounds(local?.currentRange, scope.onCurrentMatchBounds)
            Text(
                text = annotated,
                style = TextStyle(
                    fontFamily = FontFamily.Monospace,
                    fontSize = scope.bodySize * RichTextMetrics.MONO_SCALE,
                    color = scope.colors.body,
                ),
                softWrap = false,
                onTextLayout = bounds.onTextLayout,
                modifier = bounds.modifier,
            )
        }
    }
}

@Composable
private fun BlockQuoteView(block: RichTextBlock.BlockQuote, scope: RichTextScope, segmentBase: Int) {
    // A rounded vertical bar (width 3, radius 1.5, separator color) drawn in the left gutter, 9pt to the left of
    // secondary-colored content indented by indentStep (22): bar spans x 10..13, content starts at 22. The bar is
    // PAINTED (drawBehind) rather than a fillMaxHeight sibling, so it never forces intrinsic-height measurement of
    // the content - a quote wrapping a horizontal-scrolling table would otherwise crash. Nested quotes recurse,
    // each adding indentStep and drawing its own bar at +22, matching the Swift gutter math (barX = indent+10).
    val separator = scope.colors.separator
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .drawBehind {
                val left = 10.dp.toPx()
                val width = 3.dp.toPx()
                val radius = 1.5.dp.toPx()
                drawRoundRect(
                    color = separator,
                    topLeft = Offset(left, 0f),
                    size = Size(width, size.height),
                    cornerRadius = CornerRadius(radius, radius),
                )
            }
            .padding(start = scope.theme.indentStep.dp),
        verticalArrangement = Arrangement.spacedBy(scope.theme.blockSpacing.dp),
    ) {
        var base = segmentBase
        for (child in block.blocks) {
            BlockView(child, scope.colors.secondary, scope, base)
            base += RichTextRenderedText.segmentCount(child)
        }
    }
}

@Composable
private fun ListView(block: RichTextBlock.ListBlock, color: Color, scope: RichTextScope, segmentBase: Int) {
    Column(verticalArrangement = Arrangement.spacedBy(scope.theme.listSpacing.dp)) {
        var base = segmentBase
        block.items.forEachIndexed { index, itemBlocks ->
            val marker = if (block.ordered) "${block.start + index}." else "•"
            ListItemView(marker, itemBlocks, color, scope, base)
            base += itemBlocks.sumOf { RichTextRenderedText.segmentCount(it) }
        }
    }
}

@Composable
private fun ListItemView(marker: String, itemBlocks: List<RichTextBlock>, color: Color, scope: RichTextScope, segmentBase: Int) {
    Row(Modifier.fillMaxWidth()) {
        // Leading gutter (at least indentStep) holding the bullet/ordinal in the secondary color, so item content
        // aligns at indentStep; nested lists indent additively via their own gutter. widthIn(min) rather than a
        // hard width so a wide marker (e.g. "100.") pushes content right instead of clipping, like Swift's tab stop.
        Box(Modifier.widthIn(min = scope.theme.indentStep.dp).padding(end = 2.dp)) {
            Text(
                text = marker,
                style = TextStyle(fontSize = scope.bodySize, color = scope.colors.secondary),
                softWrap = false,
                maxLines = 1,
            )
        }
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(scope.theme.blockSpacing.dp),
        ) {
            var base = segmentBase
            for (child in itemBlocks) {
                BlockView(child, color, scope, base)
                base += RichTextRenderedText.segmentCount(child)
            }
        }
    }
}

@Composable
private fun ThematicBreakView(scope: RichTextScope) {
    HorizontalDivider(thickness = 1.dp, color = scope.colors.separator)
}

// MARK: - Inline text + images

@Composable
internal fun RichInlineText(
    result: RichTextInlineResult,
    scope: RichTextScope,
    style: TextStyle,
    modifier: Modifier = Modifier,
    currentMatch: RichTextRange? = null,
) {
    val inlineContent = rememberInlineImageContent(result.images, scope)
    CodePillText(result, style, scope.colors.codeFill, modifier, inlineContent, currentMatch, scope.onCurrentMatchBounds)
}

// The find hook a text composable attaches when it holds the CURRENT match: the text layout and the position on
// screen are captured, and once both are known the match's bounds are reported in window coordinates - the one
// space a scroller elsewhere in the hierarchy can convert from. Nothing is attached when there is no current match.
internal class MatchBoundsHooks(val onTextLayout: (TextLayoutResult) -> Unit, val modifier: Modifier)

@Composable
internal fun rememberMatchBounds(currentMatch: RichTextRange?, report: ((Rect?) -> Unit)?): MatchBoundsHooks {
    if (currentMatch == null || report == null) {
        return remember { MatchBoundsHooks({}, Modifier) }
    }
    var layout by remember { mutableStateOf<TextLayoutResult?>(null) }
    var coordinates by remember { mutableStateOf<LayoutCoordinates?>(null) }
    LaunchedEffect(currentMatch, layout, coordinates, report) {
        val laidOut = layout ?: return@LaunchedEffect
        val coords = coordinates ?: return@LaunchedEffect
        if (!coords.isAttached) return@LaunchedEffect
        report(matchBounds(laidOut, currentMatch, coords))
    }
    return remember {
        MatchBoundsHooks(
            onTextLayout = { layout = it },
            modifier = Modifier.onGloballyPositioned { coordinates = it },
        )
    }
}

// The union of the first and last character boxes of [range], in window coordinates: enough to scroll to.
private fun matchBounds(layout: TextLayoutResult, range: RichTextRange, coords: LayoutCoordinates): Rect? {
    val length = layout.layoutInput.text.length
    val start = range.start.coerceIn(0, maxOf(0, length - 1))
    val end = (range.end - 1).coerceIn(start, maxOf(0, length - 1))
    if (length == 0) return null
    val first = layout.getBoundingBox(start)
    val last = layout.getBoundingBox(end)
    val local = Rect(
        minOf(first.left, last.left), minOf(first.top, last.top),
        maxOf(first.right, last.right), maxOf(first.bottom, last.bottom),
    )
    val topLeft = coords.localToWindow(Offset(local.left, local.top))
    return Rect(topLeft.x, topLeft.y, topLeft.x + local.width, topLeft.y + local.height)
}

// Renders inline text, painting a rounded pill (radius 3, 2dp horizontal / 1dp vertical padding, codeFill)
// behind every inline-code span - the Stage E phase-2 replacement for the flat square background. The pill is
// drawn per line segment from the text layout, so a code span that wraps across a line break gets a pill on each
// line, matching the Apple painter. Falls back to a plain Text when there are no code spans (the common case).
@Composable
internal fun CodePillText(
    result: RichTextInlineResult,
    style: TextStyle,
    codeFill: Color,
    modifier: Modifier = Modifier,
    inlineContent: Map<String, InlineTextContent> = emptyMap(),
    currentMatch: RichTextRange? = null,
    onCurrentMatchBounds: ((Rect?) -> Unit)? = null,
) {
    val bounds = rememberMatchBounds(currentMatch, onCurrentMatchBounds)
    if (result.codeSpans.isEmpty()) {
        Text(
            text = result.text, style = style, inlineContent = inlineContent,
            onTextLayout = bounds.onTextLayout, modifier = modifier.then(bounds.modifier),
        )
        return
    }
    val layout = remember { mutableStateOf<TextLayoutResult?>(null) }
    Text(
        text = result.text,
        style = style,
        inlineContent = inlineContent,
        onTextLayout = { layout.value = it; bounds.onTextLayout(it) },
        modifier = modifier.then(bounds.modifier).drawBehind {
            val result2 = layout.value ?: return@drawBehind
            val hPad = 2.dp.toPx()
            val vPad = 1.dp.toPx()
            val radius = CornerRadius(3.dp.toPx(), 3.dp.toPx())
            for (span in result.codeSpans) {
                for (rect in codeSpanRects(result2, span.start, span.end)) {
                    drawRoundRect(
                        color = codeFill,
                        topLeft = Offset(rect.left - hPad, rect.top - vPad),
                        size = Size(rect.width + 2 * hPad, rect.height + 2 * vPad),
                        cornerRadius = radius,
                    )
                }
            }
        },
    )
}

// Per-line-segment bounding rects for the character range [start, end) in a laid-out text. One rect per line the
// range spans, so a wrapped code span yields multiple pills. Range-clamped to the laid-out text length.
private fun codeSpanRects(layout: TextLayoutResult, start: Int, end: Int): List<Rect> {
    val safeEnd = minOf(end, layout.layoutInput.text.length)
    if (safeEnd <= start) return emptyList()
    val rects = ArrayList<Rect>()
    val firstLine = layout.getLineForOffset(start)
    val lastLine = layout.getLineForOffset(safeEnd - 1)
    for (line in firstLine..lastLine) {
        val lineStart = maxOf(start, layout.getLineStart(line))
        val lineEnd = minOf(safeEnd, layout.getLineEnd(line, visibleEnd = true))
        if (lineEnd <= lineStart) continue
        val left = layout.getHorizontalPosition(lineStart, usePrimaryDirection = true)
        val right = layout.getHorizontalPosition(lineEnd, usePrimaryDirection = true)
        rects.add(Rect(minOf(left, right), layout.getLineTop(line), maxOf(left, right), layout.getLineBottom(line)))
    }
    return rects
}

// Builds the InlineTextContent map for images that appear inline among text. Each reserves a box sized from the
// cached natural pixel size (capped) or a 4:3 default, then draws the CachedImage; a disallowed scheme shows an
// alt-text placeholder instead of ever fetching. Empty for the common text-only paragraph.
@Composable
private fun rememberInlineImageContent(
    images: List<RichTextInlineImageRef>,
    scope: RichTextScope,
): Map<String, InlineTextContent> {
    if (images.isEmpty()) return emptyMap()
    val context = LocalContext.current
    val density = LocalDensity.current
    // Memoized on the (stable, already-memoized) image list so the reserved-size computation - which reads the
    // cached pixel size (a disk stat on a cold cache) - runs once per content change, not every recomposition.
    return remember(images, scope.colors, density) {
        images.associate { ref ->
            val allowed = RichTextURLPolicy.allowsImage(ref.url)
            val pixel = if (allowed) ImageStore.shared(context).cachedPixelSize(ref.url) else null
            val widthDp = INLINE_IMAGE_WIDTH_DP
            val rawHeightDp = if (pixel != null && pixel.width > 0) widthDp * pixel.height / pixel.width else widthDp * 3f / 4f
            // Clamp so a pathological aspect ratio (e.g. 1x10000) cannot reserve an enormous blank box.
            val heightDp = rawHeightDp.coerceIn(1f, widthDp * 8f)
            val widthSp = with(density) { widthDp.dp.toSp() }
            val heightSp = with(density) { heightDp.dp.toSp() }
            ref.id to InlineTextContent(
                Placeholder(widthSp, heightSp, PlaceholderVerticalAlign.AboveBaseline),
            ) {
                if (allowed) {
                    CachedImage(
                        url = ref.url,
                        modifier = Modifier.fillMaxSize(),
                        cornerRadius = 6.dp,
                        contentMode = ContentMode.Fit,
                        maxPixelWidth = IMAGE_DECODE_MAX_PX,
                        contentDescription = ref.alt.ifEmpty { null },
                    )
                } else {
                    AltPlaceholderBox(ref.alt, scope, Modifier.fillMaxSize())
                }
            }
        }
    }
}

@Composable
private fun BlockImageView(image: RichTextInline.Image, scope: RichTextScope) {
    if (!RichTextURLPolicy.allowsImage(image.url)) {
        AltPlaceholderBox(image.alt, scope, Modifier.fillMaxWidth().widthIn(max = BLOCK_IMAGE_MAX_WIDTH_DP.dp))
        return
    }
    // Cap the display width at the Swift defaultMaxWidth (320) and the decode/cache size at 320px (an OOM guard,
    // matching Swift): a 4000x4000 source is not retained as a ~64 MB bitmap. CachedImage reserves height from the
    // cached aspect ratio and shows a neutral placeholder while loading, with alt as the TalkBack description.
    CachedImage(
        url = image.url,
        modifier = Modifier.fillMaxWidth().widthIn(max = BLOCK_IMAGE_MAX_WIDTH_DP.dp),
        cornerRadius = 6.dp,
        contentMode = ContentMode.Fit,
        maxPixelWidth = IMAGE_DECODE_MAX_PX,
        contentDescription = image.alt.ifEmpty { null },
    )
}

// A rounded bordered box showing alt text, for images whose scheme is not allow-listed (e.g. file:) - mirrors
// the Swift image placeholder (codeFill fill, separator border, radius 6, secondary label) without any fetch.
@Composable
private fun AltPlaceholderBox(alt: String, scope: RichTextScope, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .background(scope.colors.codeFill, RoundedCornerShape(6.dp))
            .border(1.dp, scope.colors.separator, RoundedCornerShape(6.dp))
            .padding(horizontal = 8.dp, vertical = 10.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = if (alt.isEmpty()) "image unavailable" else "$alt (unavailable)",
            style = TextStyle(fontSize = 12.sp, color = scope.colors.secondary),
        )
    }
}

// Applies syntax-highlighter token colors to fenced code as SpanStyle runs (engine-agnostic tokens from the
// ported highlighter). With highlighting off, the code renders in a single body color. Token ranges are guarded
// to the code length exactly like the Swift apply().
private fun buildCodeAnnotated(
    code: String,
    language: String?,
    highlighting: Boolean,
    colors: RichTextColors,
) = buildAnnotatedString {
    append(code)
    if (!highlighting) return@buildAnnotatedString
    val profile = SyntaxProfile.profile(language)
    for (token in RichTextSyntaxHighlighter.tokenize(code, profile)) {
        if (token.start < 0 || token.end > code.length) continue
        val color = when (token.type) {
            RichTextSyntaxHighlighter.TokenType.COMMENT -> colors.comment
            RichTextSyntaxHighlighter.TokenType.STRING -> colors.string
            RichTextSyntaxHighlighter.TokenType.NUMBER -> colors.number
            RichTextSyntaxHighlighter.TokenType.KEYWORD -> colors.keyword
        }
        addStyle(SpanStyle(color = color), token.start, token.end)
    }
}
