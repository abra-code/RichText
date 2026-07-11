package com.abracode.richtext.demo

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.abracode.richtext.rendering.RichTextTheme

/**
 * Stage A shell. Confirms the toolchain end-to-end: the demo app applies the Compose plugin, depends on the
 * :richtext library (referenced below via [RichTextTheme]), which in turn resolves AsyncImageCache through the
 * sibling composite build. Stage F replaces this with the document gallery / streaming simulator screens that
 * mirror Demo/.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { ScaffoldScreen() }
    }
}

@Composable
private fun ScaffoldScreen() {
    // Touch the library type so the :richtext dependency is exercised at compile and link time, not just declared.
    val theme = RichTextTheme.Default
    MaterialTheme {
        Surface(modifier = Modifier.fillMaxSize()) {
            Column(modifier = Modifier.padding(24.dp)) {
                Text("RichText for Android", style = MaterialTheme.typography.headlineSmall)
                Text("Stage A scaffolding - renderer arrives in Stage D.")
                Text("Default indent step: ${theme.indentStep.toInt()}dp")
            }
        }
    }
}
