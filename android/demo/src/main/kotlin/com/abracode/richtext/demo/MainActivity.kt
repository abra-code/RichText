package com.abracode.richtext.demo

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.abracode.richtext.rendering.RichText

/**
 * Demo shell. Renders a feature-tour document through the Stage D Compose renderer. Stage F expands this into
 * the document gallery / streaming simulator / theme-toggle screens that mirror Demo/.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { DemoScreen() }
    }
}

@Composable
private fun DemoScreen() {
    MaterialTheme {
        Surface(modifier = Modifier.fillMaxSize()) {
            RichText(
                markdown = SAMPLE,
                modifier = Modifier
                    .verticalScroll(rememberScrollState())
                    .padding(16.dp),
            )
        }
    }
}

private val SAMPLE = """
    # RichText for Android

    A feature tour with **strong**, *emphasis*, ***both***, ~~strikethrough~~, `inline code`,
    a [link](https://swift.org), and an autolinked https://example.com.

    ## Code

    ```kotlin
    fun greet(name: String): String {
        return "Hello, ${'$'}name!"  // a comment
    }
    ```

    > A block quote that renders with a bar,
    > > and a nested quote inside it.

    ## Lists

    1. Parse the markdown
    2. Build the model
       - totality is sacred
       - bounds are preserved
    3. Render per block

    ## A table

    | Block | Renders as |
    | :-- | :-: |
    | heading | sized text |
    | code | a card |
    | table | a grid |

    ---

    The end.
""".trimIndent()
