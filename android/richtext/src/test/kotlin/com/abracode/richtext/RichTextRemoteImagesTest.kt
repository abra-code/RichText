package com.abracode.richtext

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

// Port of the policy and placeholder cases in Tests/RichTextTests/RichTextRemoteImagesTests.swift: which images
// RichTextRemoteImages governs, and what a held or failed image's placeholder says.
class RichTextRemoteImagesTest {

    @Test fun onlyWebImagesAreRemote() {
        assertTrue(RichTextURLPolicy.isRemoteImage("https://x.test/y.png"))
        assertTrue("schemes are case-insensitive", RichTextURLPolicy.isRemoteImage("HTTP://x.test/y.png"))
        assertFalse(RichTextURLPolicy.isRemoteImage("data:image/png;base64,AAAA"))
        assertFalse(RichTextURLPolicy.isRemoteImage("file:///sdcard/a.png"))
        assertFalse(RichTextURLPolicy.isRemoteImage("javascript:alert(1)"))
        assertFalse(RichTextURLPolicy.isRemoteImage("img/a.png"))
    }

    @Test fun heldPlaceholdersNameTheHost() {
        val url = "https://charts.example/c.png"
        assertEquals("chart\nTap to load from charts.example",
                     RichTextImagePlaceholder.label("chart", url, false, RichTextImageHold.AWAITING_CLICK, "Tap"))
        assertEquals("chart\nNot loaded from charts.example: remote images are off",
                     RichTextImagePlaceholder.label("chart", url, false, RichTextImageHold.OFF, "Tap"))
        assertEquals("Image\nTap to load from charts.example",
                     RichTextImagePlaceholder.label("", url, false, RichTextImageHold.AWAITING_CLICK, "Tap"))
    }

    @Test fun theHostIsShownAsWritten() {
        // Percent escapes are kept, so an escaped "/" cannot pass one domain off as another.
        assertEquals("a\nTap to load from evil.example%2Fapple.com",
                     RichTextImagePlaceholder.label("a", "https://evil.example%2Fapple.com/x.png", false,
                                                    RichTextImageHold.AWAITING_CLICK, "Tap"))
        // A non-ASCII host shows escaped, as Swift's URL gives it: a Cyrillic look-alike cannot pass for a real domain.
        assertEquals("a\nTap to load from %D0%B0pple.com",
                     RichTextImagePlaceholder.label("a", "https://\u0430pple.com/x.png", false,
                                                    RichTextImageHold.AWAITING_CLICK, "Tap"))
        // A host URI cannot parse as a server name loses its port and user information, as in Swift.
        assertEquals("a\nTap to load from a_b.example",
                     RichTextImagePlaceholder.label("a", "https://u@a_b.example:8080/x.png", false,
                                                    RichTextImageHold.AWAITING_CLICK, "Tap"))
        assertEquals("a\nTap to load from the web",
                     RichTextImagePlaceholder.label("a", "not a url", false, RichTextImageHold.AWAITING_CLICK, "Tap"))
    }

    @Test fun unheldPlaceholders() {
        assertEquals("chart (unavailable)", RichTextImagePlaceholder.label("chart", null, true, RichTextImageHold.NONE, "Tap"))
        assertEquals("image unavailable", RichTextImagePlaceholder.label("", null, true, RichTextImageHold.NONE, "Tap"))
        assertEquals("chart", RichTextImagePlaceholder.label("chart", null, false, RichTextImageHold.NONE, "Tap"))
        assertEquals("loading image...", RichTextImagePlaceholder.label("", null, false, RichTextImageHold.NONE, "Tap"))
    }
}
