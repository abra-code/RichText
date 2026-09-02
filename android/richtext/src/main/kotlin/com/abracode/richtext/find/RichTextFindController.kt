package com.abracode.richtext.find

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.geometry.Rect
import com.abracode.richtext.model.RichTextDocument
import com.abracode.richtext.rendering.RichTextHighlightStyle
import com.abracode.richtext.rendering.RichTextHighlights
import com.abracode.richtext.rendering.RichTextRenderedText
import com.abracode.richtext.search.RichTextRange
import com.abracode.richtext.search.RichTextSearch
import com.abracode.richtext.search.RichTextSearchOptions

// Port of Sources/RichText/Find/RichTextFindController.swift - layer 3: the state behind a find bar over ONE
// document. It owns the query and options, runs the engine over the rendered text it is bound to, and tracks
// which match the reader is on. It knows nothing about composables: RichTextFindBar edits it, `RichText(find =
// controller)` binds a document to it and paints its highlights, and a host with its own search field can drive
// `query` directly and never show the bar. Snapshot state (mutableStateOf) rather than StateFlow, like the
// ChatView store, so composables observe it for free.
//
// It keeps ranges, not matches: a bar shows "3 of 12" and paints, never a snippet.
class RichTextFindController {

    private var queryState by mutableStateOf("")
    private var optionsState by mutableStateOf(RichTextSearchOptions.Default)

    /** The text to find. Setting it re-runs the search; "" clears (the engine matches nothing for it). */
    var query: String
        get() = queryState
        set(value) {
            if (queryState == value) return
            queryState = value
            recompute()
        }

    var options: RichTextSearchOptions
        get() = optionsState
        set(value) {
            if (optionsState == value) return
            optionsState = value
            recompute()
        }

    /** Whether the bar is shown. The controller only stores this; the host's layout reads it. */
    var isPresented by mutableStateOf(false)

    /**
     * Bumped by every `present(focus = true)`, so a repeat request while the bar is open still puts focus back in
     * the field. The bar records the request it honored in [focusHonored], so a bar re-created later does not
     * honor it twice.
     */
    var focusRequests by mutableStateOf(0)
        private set
    var focusHonored by mutableStateOf(0)
        private set

    /** Colors for the painted ranges. */
    var style by mutableStateOf(RichTextHighlightStyle.Default)

    var ranges: List<RichTextRange> by mutableStateOf(emptyList())
        private set

    /** Index into [ranges] of the match the reader is on; null when there are none. */
    var currentIndex: Int? by mutableStateOf(null)
        private set

    /**
     * The current match's bounds in WINDOW coordinates, reported by the RichText composable after layout (null
     * until it is laid out, or when there is no current match). A host scroller brings it into view from this.
     */
    var currentMatchBounds: Rect? by mutableStateOf(null)
        internal set

    /** The rendered text being searched (bound by `RichText(find = ...)`, or by hand for a headless host). */
    var text: String by mutableStateOf("")
        private set

    // --- Binding to a document. ---

    /** Search this rendered text from now on; the cursor is kept when its range survives, else back to the first. */
    fun bind(text: String) {
        if (text == this.text) return
        this.text = text
        recompute()
    }

    /** Bind to a document: the ranges the controller finds are the ranges the composable paints. */
    fun bind(document: RichTextDocument) = bind(RichTextRenderedText.layout(document).text)

    // --- Navigation. ---

    fun next() = step(1)

    fun previous() = step(-1)

    /** Jump to a specific match (a result-list tap). */
    fun select(index: Int) {
        if (index in ranges.indices) currentIndex = index
    }

    /** Hide the bar and clear the query, so nothing stays painted. */
    fun dismiss() {
        isPresented = false
        query = ""
    }

    /**
     * Show the bar. With [focus] (the reader's own gesture) its field takes focus, again if the bar is already
     * open; without it (a host driving [query] from its own search field) the bar appears and focus stays where
     * the reader is typing.
     */
    fun present(focus: Boolean = true) {
        isPresented = true
        if (focus) focusRequests += 1
    }

    /** The bar took the focus [focusRequests] asked for. */
    fun markFocusHonored() {
        focusHonored = focusRequests
    }

    // --- Derived. ---

    /** What `RichText(highlights = ...)` should paint: null when there is nothing to paint. */
    val highlights: RichTextHighlights?
        get() = if (ranges.isEmpty()) null else RichTextHighlights(ranges, currentIndex, style)

    /** "3 of 12", "No matches", or "" for an empty query. With `options.limit` reached, "3 of 500+". */
    val summary: String
        get() {
            if (queryState.isBlank()) return ""
            val index = currentIndex ?: return "No matches"
            if (ranges.isEmpty()) return "No matches"
            val capped = optionsState.limit?.let { ranges.size >= it } ?: false
            return "${index + 1} of ${ranges.size}${if (capped) "+" else ""}"
        }

    // --- Private. ---

    private fun step(delta: Int) {
        if (ranges.isEmpty()) return
        val count = ranges.size
        val base = currentIndex ?: if (delta > 0) -1 else 0
        currentIndex = ((base + delta) % count + count) % count
    }

    private fun recompute() {
        val previousRange = currentIndex?.let { ranges.getOrNull(it) }
        ranges = RichTextSearch.ranges(text, query, options)
        val kept = previousRange?.let { ranges.indexOf(it) } ?: -1
        currentIndex = when {
            ranges.isEmpty() -> null
            kept >= 0 -> kept
            else -> 0
        }
        if (currentIndex == null) currentMatchBounds = null
    }
}
