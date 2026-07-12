package com.abracode.richtext

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// Port of the policy allow-list cases from Tests/RichTextTests/RichTextURLPolicyTests.swift. The attributed-
// string render-boundary cases (javascript/http tappability) belong to the Compose renderer (Stage D), not the
// pure-logic layer, so they are not here.
class RichTextURLPolicyTest {

    @Test fun allowedLinkSchemes() {
        assertNotNull(RichTextURLPolicy.allowedLink("https://example.com"))
        assertNotNull(RichTextURLPolicy.allowedLink("http://example.com"))
        assertNotNull(RichTextURLPolicy.allowedLink("mailto:a@b.com"))
        assertNotNull(RichTextURLPolicy.allowedLink("tel:+15551234567"))
    }

    @Test fun rejectedLinkSchemes() {
        assertNull(RichTextURLPolicy.allowedLink("javascript:alert(1)"))
        assertNull("scheme match must be case-insensitive", RichTextURLPolicy.allowedLink("JavaScript:alert(1)"))
        assertNull(RichTextURLPolicy.allowedLink("file:///etc/passwd"))
        assertNull(RichTextURLPolicy.allowedLink("data:text/html,<b>hi</b>"))
        assertNull("a scheme-less/relative link is rejected", RichTextURLPolicy.allowedLink("/relative/path"))
    }

    @Test fun allowedImageSchemes() {
        assertTrue(RichTextURLPolicy.allowsImage("https://x.test/y.png"))
        assertTrue(RichTextURLPolicy.allowsImage("http://x.test/y.png"))
        assertTrue(RichTextURLPolicy.allowsImage("data:image/png;base64,AAAA"))
    }

    @Test fun rejectedImageSchemes() {
        assertFalse("a file: image must never be fetched from disk", RichTextURLPolicy.allowsImage("file:///etc/passwd"))
        assertFalse(RichTextURLPolicy.allowsImage("javascript:alert(1)"))
    }
}
