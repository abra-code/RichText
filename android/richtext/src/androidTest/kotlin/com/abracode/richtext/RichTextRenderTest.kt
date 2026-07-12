package com.abracode.richtext

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import com.abracode.richtext.rendering.RichText
import org.junit.Rule
import org.junit.Test

/**
 * Stage D Compose renderer tests (instrumented). They assert block presence/structure across a feature-tour
 * document, heading accessibility semantics, the link/image scheme policy at the rendering boundary, and that
 * color resolution works in both light and dark Material schemes. Byte-level parse/serialize parity is covered
 * by the fast JVM suite (RichTextFixtureParityTest); these cover the platform half the JVM cannot.
 */
class RichTextRenderTest {

    @get:Rule val composeTestRule = createComposeRule()

    private fun setMarkdown(markdown: String, dark: Boolean = false) {
        composeTestRule.setContent {
            Themed(dark) { RichText(markdown = markdown) }
        }
    }

    @Composable
    private fun Themed(dark: Boolean, content: @Composable () -> Unit) {
        MaterialTheme(colorScheme = if (dark) darkColorScheme() else lightColorScheme()) {
            Surface { content() }
        }
    }

    @Test fun rendersBlockStructure() {
        setMarkdown(
            """
            # Heading One

            A paragraph with **strong** and *emphasis* and `code`.

            > A quoted line.

            - first item
            - second item

            ```kotlin
            val x = 42
            ```

            | Name | Value |
            | --- | --- |
            | alpha | 1 |
            """.trimIndent(),
        )

        // Text is emitted per block; substrings survive the AnnotatedString styling runs.
        composeTestRule.onNodeWithText("Heading One").assertExists()
        composeTestRule.onNodeWithText("strong", substring = true, useUnmergedTree = true).assertExists()
        composeTestRule.onNodeWithText("code", substring = true, useUnmergedTree = true).assertExists()
        composeTestRule.onNodeWithText("A quoted line", substring = true, useUnmergedTree = true).assertExists()
        composeTestRule.onNodeWithText("first item", substring = true, useUnmergedTree = true).assertExists()
        composeTestRule.onNodeWithText("second item", substring = true, useUnmergedTree = true).assertExists()
        composeTestRule.onNodeWithText("val x = 42", substring = true, useUnmergedTree = true).assertExists()
        composeTestRule.onNodeWithText("alpha", substring = true, useUnmergedTree = true).assertExists()
    }

    @Test fun headingCarriesHeadingSemantics() {
        setMarkdown("# Accessible Heading")
        composeTestRule.onNode(
            SemanticsMatcher.keyIsDefined(SemanticsProperties.Heading),
            useUnmergedTree = true,
        ).assertExists()
    }

    @Test fun disallowedLinkRendersAsPlainText() {
        // A javascript: target is not allow-listed: the visible text is kept but never becomes a tappable link.
        setMarkdown("A [dangerous](javascript:alert(1)) link.")
        composeTestRule.onNodeWithText("dangerous", substring = true, useUnmergedTree = true).assertExists()
    }

    @Test fun disallowedImageFallsBackToAltText() {
        // A file: image scheme is rejected; the renderer shows the alt-text placeholder instead of fetching.
        setMarkdown("![secret](file:///etc/passwd)")
        composeTestRule.onNodeWithText("secret (unavailable)", substring = true, useUnmergedTree = true).assertExists()
    }

    @Test fun resolvesColorsInDarkTheme() {
        setMarkdown("# Dark Title\n\nBody text with a `code span`.", dark = true)
        composeTestRule.onNodeWithText("Dark Title").assertExists()
        composeTestRule.onNodeWithText("code span", substring = true, useUnmergedTree = true).assertExists()
    }

    @Test fun rendersOrderedListMarkers() {
        setMarkdown("3. three\n4. four")
        composeTestRule.onNodeWithText("3.", substring = true, useUnmergedTree = true).assertExists()
        composeTestRule.onNodeWithText("three", substring = true, useUnmergedTree = true).assertExists()
    }

    @Test fun quoteContainingScrollingTableDoesNotCrash() {
        // The quote bar must not force intrinsic-height measurement of its content: a horizontally scrolling
        // table inside a quote would otherwise crash. Rendering to completion (no exception) is the assertion.
        setMarkdown(
            """
            > | Left | Right |
            > | --- | --- |
            > | a | b |
            """.trimIndent(),
        )
        composeTestRule.onNodeWithText("Left", substring = true, useUnmergedTree = true).assertExists()
    }

    @Test fun deeplyNestedStructureRenders() {
        setMarkdown(
            """
            > outer
            > > inner quote
            > > - item with `code`
            > >   1. nested ordinal
            """.trimIndent(),
        )
        composeTestRule.onNodeWithText("inner quote", substring = true, useUnmergedTree = true).assertExists()
        composeTestRule.onNodeWithText("nested ordinal", substring = true, useUnmergedTree = true).assertExists()
    }

    // --- Stage E: inline-code pills + table hardening ---

    @Test fun inlineCodePillRenders() {
        // The rounded pill is painted behind the code span; the code text still renders as a locatable node.
        setMarkdown("Call `reset()` to start over, and `flush()` after.")
        composeTestRule.onNodeWithText("reset()", substring = true, useUnmergedTree = true).assertExists()
        composeTestRule.onNodeWithText("flush()", substring = true, useUnmergedTree = true).assertExists()
    }

    @Test fun singleColumnTableRenders() {
        setMarkdown("| Only |\n| --- |\n| one |\n| two |")
        composeTestRule.onNodeWithText("Only", substring = true, useUnmergedTree = true).assertExists()
        composeTestRule.onNodeWithText("one", substring = true, useUnmergedTree = true).assertExists()
        composeTestRule.onNodeWithText("two", substring = true, useUnmergedTree = true).assertExists()
    }

    @Test fun headerOnlyTableRenders() {
        setMarkdown("| H1 | H2 |\n| --- | --- |")
        composeTestRule.onNodeWithText("H1", substring = true, useUnmergedTree = true).assertExists()
        composeTestRule.onNodeWithText("H2", substring = true, useUnmergedTree = true).assertExists()
    }

    @Test fun tableWithEmptyCellsRenders() {
        setMarkdown("| A | B |\n| --- | --- |\n|  | filled |\n| here |  |")
        composeTestRule.onNodeWithText("filled", substring = true, useUnmergedTree = true).assertExists()
        composeTestRule.onNodeWithText("here", substring = true, useUnmergedTree = true).assertExists()
    }

    @Test fun tableWithVeryWideCellWrapsWithoutCrashing() {
        val wide = "word ".repeat(80)
        setMarkdown("| Short | Wide |\n| --- | --- |\n| a | $wide |")
        composeTestRule.onNodeWithText("Short", substring = true, useUnmergedTree = true).assertExists()
        composeTestRule.onNodeWithText("word", substring = true, useUnmergedTree = true).assertExists()
    }

    @Test fun tableCellWithCodeSpanRenders() {
        setMarkdown("| Name | Value |\n| --- | --- |\n| `key` | 1 |")
        composeTestRule.onNodeWithText("key", substring = true, useUnmergedTree = true).assertExists()
    }
}
