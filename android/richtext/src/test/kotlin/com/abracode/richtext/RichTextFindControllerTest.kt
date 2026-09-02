package com.abracode.richtext

import com.abracode.richtext.find.RichTextFindController
import com.abracode.richtext.model.RichTextDocument
import com.abracode.richtext.search.RichTextRange
import com.abracode.richtext.search.RichTextSearchOptions
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// Port of the controller half of Tests/RichTextTests/RichTextFindTests.swift: the cursor wraps, survives a
// re-bind, clears with the query, and focus requests are the reader's, not a host's.
class RichTextFindControllerTest {

    private val markdown = "The quick brown fox jumps over the lazy dog. The fox again.\n\nA second paragraph about a fox."

    @Test fun cursorWrapsAndSummaryReads() {
        val controller = RichTextFindController()
        controller.bind(RichTextDocument.parse(markdown))
        assertEquals("", controller.summary)
        controller.query = "fox"
        assertEquals(3, controller.ranges.size)
        assertEquals(0, controller.currentIndex)
        assertEquals("1 of 3", controller.summary)
        controller.next()
        controller.next()
        assertEquals(2, controller.currentIndex)
        controller.next()
        assertEquals("wraps forward", 0, controller.currentIndex)
        controller.previous()
        assertEquals("wraps backward", 2, controller.currentIndex)
        assertEquals(2, controller.highlights?.current)

        controller.query = "zebra"
        assertEquals("No matches", controller.summary)
        assertNull(controller.currentIndex)
        assertNull(controller.highlights)

        controller.query = ""
        assertEquals("", controller.summary)
        controller.query = "   "
        assertEquals("a blank query is not a search", "", controller.summary)
    }

    @Test fun keepsCurrentMatchAcrossRebindAndOptionsChange() {
        val controller = RichTextFindController()
        controller.bind("fox one fox two Fox three")
        controller.query = "fox"
        controller.next()
        assertEquals(1, controller.currentIndex)
        controller.bind("fox one fox two Fox three")
        assertEquals("the same text re-bound moves nothing", 1, controller.currentIndex)
        controller.bind("intro fox one fox two Fox three")
        assertEquals("the old range is gone: back to the first", 0, controller.currentIndex)
        controller.options = RichTextSearchOptions(caseSensitive = true)
        assertEquals(2, controller.ranges.size)
        controller.options = RichTextSearchOptions(limit = 1)
        assertEquals(1, controller.ranges.size)
        assertEquals("1 of 1+", controller.summary)
    }

    @Test fun reportsAnInvalidExpression() {
        val controller = RichTextFindController()
        controller.bind("fox (fox) fox")
        controller.options = RichTextSearchOptions(regularExpression = true)
        controller.query = "(fox"
        assertEquals("Invalid expression", controller.summary)
        assertTrue(controller.ranges.isEmpty())
        controller.query = "\\(fox\\)"
        assertEquals("1 of 1", controller.summary)
        assertEquals(listOf(RichTextRange(4, 9)), controller.ranges)
        // Back to literal: the same characters are a fine query that the text does not contain.
        controller.options = RichTextSearchOptions()
        assertEquals("No matches", controller.summary)
    }

    @Test fun presentBumpsFocusRequestsUnlessAHostAsksNotTo() {
        val controller = RichTextFindController()
        controller.present()
        controller.present()
        assertTrue(controller.isPresented)
        assertEquals(2, controller.focusRequests)
        controller.markFocusHonored()
        assertEquals(2, controller.focusHonored)
        controller.present(focus = false)
        assertEquals("a host's present leaves focus alone", 2, controller.focusRequests)
    }

    @Test fun dismissHidesAndClears() {
        val controller = RichTextFindController()
        controller.bind("fox")
        controller.present()
        controller.query = "fox"
        assertTrue(controller.isPresented)
        controller.dismiss()
        assertFalse(controller.isPresented)
        assertEquals("", controller.query)
        assertTrue(controller.ranges.isEmpty())
        assertNull(controller.currentMatchBounds)
    }
}
