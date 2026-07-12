package com.abracode.richtext.demo

/** A named Markdown document for the demo gallery. */
data class DemoDocument(val name: String, val markdown: String)

/**
 * Curated showcase documents for the demo. Unlike the shared `Fixtures/markdown` corpus (which uses reserved
 * example.test URLs because it exists for byte-for-byte parse PARITY, not rendering), these use real, loadable
 * images (picsum.photos) and real links, so the demo actually shows pictures and working navigation. They lead
 * the gallery; the fixture corpus follows for parsing breadth.
 */
val SHOWCASE_DOCUMENTS: List<DemoDocument> = listOf(
    DemoDocument(
        "Welcome",
        """
        # RichText for Android

        A high-fidelity Markdown renderer that draws a whole document as one selectable, scrollable view.

        ![Banner](https://picsum.photos/seed/richtext/900/320)

        It renders **strong**, *emphasis*, `inline code`, [links](https://github.com/abra-code/RichText),
        and autolinks like https://kotlinlang.org - all in native text.

        - Headings, lists, and hard breaks
        - Block quotes and GFM tables
        - Fenced code with syntax highlighting

        > A 1:1 port of the Apple RichText library.
        """.trimIndent(),
    ),
    DemoDocument(
        "Images",
        """
        # Images

        A block image renders on its own line, capped at a max width and aspect-preserved:

        ![Landscape](https://picsum.photos/seed/landscape/800/480)

        A taller image below scales to the same width cap:

        ![Portrait](https://picsum.photos/seed/portrait/480/640)

        Images load through AsyncImageCache, a two-tier memory + disk cache. An image whose scheme is not
        allow-listed (only http / https / data are) falls back to its alt text instead of ever being fetched:

        ![a local file](file:///etc/hosts)
        """.trimIndent(),
    ),
    DemoDocument(
        "Article",
        """
        # Building UI with Compose

        Jetpack Compose is Android's declarative UI toolkit. Docs:
        [developer.android.com](https://developer.android.com/jetpack/compose).

        ![Workspace](https://picsum.photos/seed/workspace/800/400)

        ## A small composable

        ```kotlin
        @Composable
        fun Greeting(name: String) {
            Text("Hello, ${'$'}name!")
        }
        ```

        ## At a glance

        | Aspect | Benefit |
        | :-- | :-- |
        | Declarative | Less UI code |
        | Kotlin-first | Type-safe |

        > RichText itself is a tree of composables.

        More in the [Kotlin docs](https://kotlinlang.org/docs).
        """.trimIndent(),
    ),
)
