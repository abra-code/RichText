package com.abracode.richtext.rendering

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.graphics.Color

/**
 * The SEMANTIC color roles the renderer draws with, resolved once per composition from the Material color
 * scheme (plus a dark-mode flag). This mirrors the Apple side, where colors are AppKit/UIKit semantic roles
 * (`RTVColors`) rather than caller-supplied values: not customizable through the theme, adaptive to light/dark.
 *
 * Role mapping (Swift `RTVColors` -> Material):
 * - body      = onSurface          (Swift `.label`, primary text)
 * - secondary = onSurfaceVariant   (Swift `.secondaryLabel`, quote text + list markers)
 * - codeFill  = surfaceVariant     (Swift `.quaternarySystemFill`, code card + inline-code pill + table header)
 * - separator = outlineVariant     (Swift `.separator`, thematic rule + table grid + quote bar)
 * - link      = a fixed adaptive blue matching the HTML serializer's #0066cc (Swift `.link` / system blue)
 *
 * Syntax colors mirror `RTVSyntaxColors` (systemPurple/Red/Blue/Green); iOS system-color values with a
 * dark-mode variant so tokenized code reads the same as on Apple.
 */
@Immutable
data class RichTextColors(
    val body: Color,
    val secondary: Color,
    val link: Color,
    val codeFill: Color,
    val separator: Color,
    val keyword: Color,
    val string: Color,
    val number: Color,
    val comment: Color,
)

/** Resolves [RichTextColors] from the ambient [MaterialTheme] and dark-mode state. */
@Composable
@ReadOnlyComposable
fun rememberRichTextColors(dark: Boolean = isSystemInDarkTheme()): RichTextColors {
    val scheme = MaterialTheme.colorScheme
    return RichTextColors(
        body = scheme.onSurface,
        secondary = scheme.onSurfaceVariant,
        link = if (dark) Color(0xFF4C9AFF) else Color(0xFF0066CC),
        codeFill = scheme.surfaceVariant,
        separator = scheme.outlineVariant,
        // iOS system colors (light / dark), used as engine-agnostic syntax token colors.
        keyword = if (dark) Color(0xFFBF5AF2) else Color(0xFFAF52DE),   // systemPurple
        string = if (dark) Color(0xFFFF453A) else Color(0xFFFF3B30),    // systemRed
        number = if (dark) Color(0xFF0A84FF) else Color(0xFF007AFF),    // systemBlue
        comment = if (dark) Color(0xFF30D158) else Color(0xFF34C759),   // systemGreen
    )
}
