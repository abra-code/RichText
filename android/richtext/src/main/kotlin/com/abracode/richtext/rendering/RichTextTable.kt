package com.abracode.richtext.rendering

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.rememberScrollState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import com.abracode.richtext.model.RichTextBlock
import com.abracode.richtext.model.RichTextColumnAlignment
import com.abracode.richtext.model.RichTextInline
import kotlin.math.roundToInt

// GFM table rendering. Apple lays tables out as tab-stop rows in the single text view and draws the grid in the
// layout manager; Compose has no equivalent, so this is a custom Layout that measures content-sized columns (the
// max cell width, last column capped so a long cell wraps instead of overflowing), places cells with per-column
// alignment and cellPadding insets, and paints the header background + 1px grid in drawBehind. When the natural
// width exceeds the container it scrolls horizontally (plan divergence #4: Apple wraps the whole table instead).
// Column widths/edges are shared from measure to draw via a remembered holder. Stage E hardens edge cases.

private const val MAX_LAST_COLUMN_WIDTH_DP = 320f

@Composable
internal fun RichTextTableView(block: RichTextBlock.Table, color: Color, scope: RichTextScope) {
    val columns = maxOf(block.headers.size, block.rows.maxOfOrNull { it.size } ?: 0)
    if (columns == 0) return

    // Header row first, then body rows (as in the Swift builder). `true` marks the header row (bold + fill).
    val allRows: List<Pair<List<List<RichTextInline>>, Boolean>> =
        listOf(block.headers to true) + block.rows.map { it to false }

    val cellStyle = TextStyle(fontSize = scope.bodySize, color = color)
    // Cell text is built with the inline builder (header cells bold), carrying code-span ranges so cells get the
    // same rounded pills as body text. Any image in a cell falls back to its alt text (no inline-content map
    // here), acceptable for the rare image-in-table case. Memoized so streaming re-renders do not rebuild cells.
    val cells: List<List<RichTextInlineResult>> = remember(block, color, scope.colors) {
        allRows.map { (row, header) ->
            (0 until columns).map { c ->
                buildRichInlines(row.getOrNull(c) ?: emptyList(), scope.colors, baseColor = color, initialBold = header)
            }
        }
    }

    val density = LocalDensity.current
    val cellPaddingPx = with(density) { scope.theme.cellPadding.dp.toPx() }
    val lastColCapPx = with(density) { MAX_LAST_COLUMN_WIDTH_DP.dp.toPx() }
    val gridPx = with(density) { 1.dp.toPx() }
    val geometry = remember { TableGeometry() }
    val separator = scope.colors.separator
    val headerFill = scope.colors.codeFill

    Box(Modifier.horizontalScroll(rememberScrollState())) {
        Layout(
            content = {
                for (r in allRows.indices) {
                    for (c in 0 until columns) {
                        CodePillText(cells[r][c], style = cellStyle, codeFill = scope.colors.codeFill)
                    }
                }
            },
            modifier = Modifier.drawBehind { drawTableDecorations(geometry, separator, headerFill, gridPx) },
        ) { measurables, _ ->
            val rows = allRows.size
            val pad2 = (cellPaddingPx * 2).roundToInt()
            val cp = cellPaddingPx.roundToInt()

            // Content width per column = max cell intrinsic width; the last column is capped so it wraps.
            val colContentW = IntArray(columns)
            measurables.forEachIndexed { idx, m ->
                val c = idx % columns
                colContentW[c] = maxOf(colContentW[c], m.maxIntrinsicWidth(Constraints.Infinity))
            }
            colContentW[columns - 1] = minOf(colContentW[columns - 1], lastColCapPx.roundToInt())

            val colW = IntArray(columns) { colContentW[it] + pad2 }
            val placeables = measurables.mapIndexed { idx, m ->
                val c = idx % columns
                m.measure(Constraints(minWidth = 0, maxWidth = colContentW[c], minHeight = 0, maxHeight = Constraints.Infinity))
            }
            val rowH = IntArray(rows)
            placeables.forEachIndexed { idx, p -> rowH[idx / columns] = maxOf(rowH[idx / columns], p.height + pad2) }

            val colEdges = IntArray(columns + 1)
            for (c in 0 until columns) colEdges[c + 1] = colEdges[c] + colW[c]
            val rowEdges = IntArray(rows + 1)
            for (r in 0 until rows) rowEdges[r + 1] = rowEdges[r] + rowH[r]

            geometry.colEdges = colEdges
            geometry.rowEdges = rowEdges
            geometry.headerBottom = rowEdges[1]   // one header row

            layout(colEdges[columns], rowEdges[rows]) {
                placeables.forEachIndexed { idx, p ->
                    val r = idx / columns
                    val c = idx % columns
                    val slack = colContentW[c] - p.width
                    val alignOffset = when (alignmentOf(block.alignments, c)) {
                        RichTextColumnAlignment.CENTER -> slack / 2
                        RichTextColumnAlignment.RIGHT -> slack
                        else -> 0
                    }
                    p.placeRelative(colEdges[c] + cp + alignOffset, rowEdges[r] + cp)
                }
            }
        }
    }
}

// Column/row edge positions (absolute px) shared from the measure pass to the draw pass. A plain holder rather
// than State: it is written during measure and read during draw of the SAME frame, so no recomposition is wanted.
private class TableGeometry {
    var colEdges: IntArray = IntArray(0)
    var rowEdges: IntArray = IntArray(0)
    var headerBottom: Int = 0
}

private fun DrawScope.drawTableDecorations(geo: TableGeometry, separator: Color, headerFill: Color, gridPx: Float) {
    val cols = geo.colEdges
    val rows = geo.rowEdges
    if (cols.size < 2 || rows.size < 2) return
    val right = cols.last().toFloat()
    val bottom = rows.last().toFloat()
    if (geo.headerBottom > 0) {
        drawRect(headerFill, topLeft = Offset(0f, 0f), size = Size(right, geo.headerBottom.toFloat()))
    }
    for (x in cols) drawLine(separator, Offset(x.toFloat(), 0f), Offset(x.toFloat(), bottom), gridPx)
    for (y in rows) drawLine(separator, Offset(0f, y.toFloat()), Offset(right, y.toFloat()), gridPx)
}

private fun alignmentOf(alignments: List<RichTextColumnAlignment>, column: Int): RichTextColumnAlignment =
    alignments.getOrElse(column) { RichTextColumnAlignment.NONE }
