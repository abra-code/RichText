package com.abracode.richtext.demo

import android.content.Context
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.abracode.richtext.rendering.RichText
import com.abracode.richtext.serialization.RichTextClipboard
import kotlinx.coroutines.delay

/**
 * Demo app mirroring Demo/ (the SwiftUI demo): a document gallery over the shared fixture corpus, a streaming
 * simulator (types a document out progressively to exercise the parser's totality), a light/dark theme toggle,
 * and a "Copy" action that puts the rendered document on the clipboard as HTML + Markdown via RichTextClipboard.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { DemoApp() }
    }
}

@Composable
private fun DemoApp() {
    val context = LocalContext.current
    // Lead with the curated showcase docs (real images + links), then the fixture corpus for parsing breadth.
    val documents = remember { SHOWCASE_DOCUMENTS + loadFixtureDocuments(context) }

    var dark by remember { mutableStateOf(false) }
    var streaming by remember { mutableStateOf(false) }
    var selected by remember { mutableIntStateOf(0) }

    val fullMarkdown = documents.getOrNull(selected)?.markdown ?: ""

    // Streaming simulator: grow a prefix of the current document over time. Re-parsing each partial prefix is
    // safe because the parser is total (never throws, never loses text) - the chat-streaming guarantee.
    var streamLength by remember { mutableIntStateOf(fullMarkdown.length) }
    LaunchedEffect(selected, streaming, fullMarkdown) {
        if (!streaming) {
            streamLength = fullMarkdown.length
            return@LaunchedEffect
        }
        streamLength = 0
        while (streamLength < fullMarkdown.length) {
            streamLength = (streamLength + 3).coerceAtMost(fullMarkdown.length)
            delay(16)
        }
    }
    val shownMarkdown = fullMarkdown.take(streamLength)

    MaterialTheme(colorScheme = if (dark) darkColorScheme() else lightColorScheme()) {
        Surface(modifier = Modifier.fillMaxSize()) {
            Column(modifier = Modifier.fillMaxSize()) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("RichText Demo", style = MaterialTheme.typography.titleLarge)
                    Spacer(Modifier.width(16.dp))
                    Text("Dark", style = MaterialTheme.typography.labelLarge)
                    Switch(checked = dark, onCheckedChange = { dark = it })
                }

                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    FilterChip(selected = streaming, onClick = { streaming = !streaming }, label = { Text("Stream") })
                    Spacer(Modifier.width(0.dp))
                    Button(onClick = {
                        RichTextClipboard.write(shownMarkdown, context, label = documents.getOrNull(selected)?.name ?: "RichText")
                        Toast.makeText(context, "Copied as HTML + Markdown", Toast.LENGTH_SHORT).show()
                    }) { Text("Copy") }
                }

                // Document gallery: one chip per fixture document.
                Row(
                    modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(16.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    documents.forEachIndexed { index, document ->
                        FilterChip(
                            selected = index == selected,
                            onClick = { selected = index },
                            label = { Text(document.name) },
                        )
                    }
                }

                HorizontalDivider()

                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f)
                        .verticalScroll(rememberScrollState())
                        .padding(16.dp),
                ) {
                    RichText(markdown = shownMarkdown)
                }
            }
        }
    }
}

// Loads the bundled Fixtures/markdown corpus (wired as assets in build.gradle.kts) as the gallery's documents.
private fun loadFixtureDocuments(context: Context): List<DemoDocument> {
    val names = context.assets.list("")?.filter { it.endsWith(".md") }?.sorted().orEmpty()
    return names.map { name ->
        val markdown = context.assets.open(name).bufferedReader().use { it.readText() }
        DemoDocument(name.removeSuffix(".md"), markdown)
    }
}
