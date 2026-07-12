package com.abracode.richtext

import com.abracode.richtext.markdown.RichTextMarkdownParser
import com.abracode.richtext.model.RichTextBlock
import com.abracode.richtext.model.RichTextColumnAlignment
import com.abracode.richtext.model.RichTextDocument
import com.abracode.richtext.model.RichTextInline
import com.abracode.richtext.serialization.RichTextHTMLSerializer
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Stage C cross-platform parity: the Swift parser is NORMATIVE and EMITS the shared fixtures
 * (Tests/RichTextTests/RichTextFixtureEmitterTests.swift); this JVM suite asserts the Kotlin port reproduces
 * them byte-for-byte. For every markdown file in `Fixtures/markdown/` it checks that the Kotlin parse tree, re-encoded to
 * the SAME canonical JSON, equals `Fixtures/expected/<name>.json`, and that `RichTextHTMLSerializer.fragment`
 * equals `Fixtures/expected/<name>.html`. Any parser or serializer drift between the two platforms fails here.
 *
 * The fixtures live at the repo root, shared with Swift; the absolute path is injected by the Gradle build as
 * the `richtext.fixtures.dir` system property (see richtext/build.gradle.kts) so the test never depends on the
 * JVM working directory. To regenerate after an intended change: `RICHTEXT_EMIT_FIXTURES=1 swift test`.
 *
 * The FixtureJson encoder below MUST stay byte-identical to the Swift `FixtureJSON` (same key order, same
 * minimal escaping, same 2-space indentation, same trailing newline) - the two are a matched pair.
 */
class RichTextFixtureParityTest {

    private val fixturesDir: File by lazy {
        val path = System.getProperty("richtext.fixtures.dir")
            ?: error("richtext.fixtures.dir system property not set (see richtext/build.gradle.kts)")
        File(path)
    }

    @Test fun parseTreesAndHtmlMatchTheSwiftEmittedFixtures() {
        val markdownDir = File(fixturesDir, "markdown")
        val expectedDir = File(fixturesDir, "expected")
        assertTrue("fixtures markdown dir missing: ${markdownDir.absolutePath}", markdownDir.isDirectory)

        val sources = markdownDir.listFiles { f -> f.isFile && f.extension == "md" }
            ?.sortedBy { it.name }
            .orEmpty()
        assertTrue("no *.md fixtures found under ${markdownDir.absolutePath}", sources.isNotEmpty())

        val failures = mutableListOf<String>()
        for (md in sources) {
            val name = md.nameWithoutExtension
            val source = md.readText(Charsets.UTF_8)
            val blocks = RichTextMarkdownParser.parse(source)

            val jsonFile = File(expectedDir, "$name.json")
            val htmlFile = File(expectedDir, "$name.html")
            if (!jsonFile.isFile) { failures += "$name: expected JSON missing (${jsonFile.name})"; continue }
            if (!htmlFile.isFile) { failures += "$name: expected HTML missing (${htmlFile.name})"; continue }

            firstDifference(jsonFile.readText(Charsets.UTF_8), FixtureJson.canonical(blocks))
                ?.let { failures += "$name.json $it" }
            firstDifference(htmlFile.readText(Charsets.UTF_8), RichTextHTMLSerializer.fragment(RichTextDocument(blocks)))
                ?.let { failures += "$name.html $it" }
        }

        assertTrue(
            "cross-platform fixture drift (regenerate with RICHTEXT_EMIT_FIXTURES=1 swift test):\n" +
                failures.joinToString("\n"),
            failures.isEmpty(),
        )
    }

    // Returns a compact description of the first line where expected and actual diverge, or null if identical.
    // Line-oriented so the message points at the exact drift without dumping kilobytes of JSON.
    private fun firstDifference(expected: String, actual: String): String? {
        if (expected == actual) return null
        val e = expected.split('\n')
        val a = actual.split('\n')
        val n = minOf(e.size, a.size)
        for (i in 0 until n) {
            if (e[i] != a[i]) {
                return "differs at line ${i + 1}:\n    expected: ${snippet(e[i])}\n    actual:   ${snippet(a[i])}"
            }
        }
        return "differs in length (expected ${e.size} lines, actual ${a.size} lines); first extra: " +
            snippet((if (a.size > e.size) a else e).getOrElse(n) { "" })
    }

    private fun snippet(line: String): String =
        if (line.length <= 200) line else line.take(200) + "... (${line.length} chars)"
}

// Canonical JSON for the parse tree - the byte-for-byte mirror of the Swift `FixtureJSON` enum. Test-only
// (never part of the library API): parity is an assertion about the model, not a shipping serializer.
private object FixtureJson {

    /** The parse tree (an array of blocks) rendered as canonical JSON with a trailing newline. */
    fun canonical(blocks: List<RichTextBlock>): String =
        render(Value.Arr(blocks.map { encodeBlock(it) }), 0) + "\n"

    // A tiny ordered JSON tree so all formatting lives in one `render` function that mirrors Swift's exactly.
    private sealed interface Value {
        data class Obj(val pairs: List<Pair<String, Value>>) : Value   // insertion-ordered; NEVER sorted
        data class Arr(val items: List<Value>) : Value
        data class Str(val value: String) : Value
        data class Integer(val value: Int) : Value
        data class Bool(val value: Boolean) : Value
        data object Null : Value
    }

    private fun render(value: Value, indent: Int): String = when (value) {
        is Value.Str -> quoted(value.value)
        is Value.Integer -> value.value.toString()
        is Value.Bool -> if (value.value) "true" else "false"
        Value.Null -> "null"
        is Value.Arr -> if (value.items.isEmpty()) "[]" else {
            val pad = "  ".repeat(indent + 1)
            val close = "  ".repeat(indent)
            val body = value.items.joinToString(",\n") { pad + render(it, indent + 1) }
            "[\n$body\n$close]"
        }
        is Value.Obj -> if (value.pairs.isEmpty()) "{}" else {
            val pad = "  ".repeat(indent + 1)
            val close = "  ".repeat(indent)
            val body = value.pairs.joinToString(",\n") { pad + quoted(it.first) + ": " + render(it.second, indent + 1) }
            "{\n$body\n$close}"
        }
    }

    // Minimal JSON string escaping. Iterates UTF-16 code units; the special cases are all ASCII (single unit),
    // and non-ASCII passes through literally, so the UTF-8 bytes match Swift's Unicode-scalar iteration.
    private fun quoted(s: String): String {
        val out = StringBuilder()
        out.append('"')
        for (c in s) {
            when (c) {
                '"' -> out.append("\\\"")
                '\\' -> out.append("\\\\")
                '\n' -> out.append("\\n")
                '\r' -> out.append("\\r")
                '\t' -> out.append("\\t")
                '\b' -> out.append("\\b")
                '\u000C' -> out.append("\\f")
                else -> if (c < ' ') {
                    val hex = c.code.toString(16)
                    out.append("\\u").append("0".repeat(4 - hex.length)).append(hex)
                } else {
                    out.append(c)
                }
            }
        }
        out.append('"')
        return out.toString()
    }

    // MARK: node -> Value (fixed key order; must match the Swift encoder exactly)

    private fun encodeBlock(block: RichTextBlock): Value = when (block) {
        is RichTextBlock.Heading -> Value.Obj(
            listOf("type" to Value.Str("heading"), "level" to Value.Integer(block.level), "inlines" to encodeInlines(block.inlines)),
        )
        is RichTextBlock.Paragraph -> Value.Obj(
            listOf("type" to Value.Str("paragraph"), "inlines" to encodeInlines(block.inlines)),
        )
        is RichTextBlock.CodeBlock -> Value.Obj(
            listOf(
                "type" to Value.Str("codeBlock"),
                "language" to (block.language?.let { Value.Str(it) } ?: Value.Null),
                "code" to Value.Str(block.code),
            ),
        )
        is RichTextBlock.BlockQuote -> Value.Obj(
            listOf("type" to Value.Str("blockQuote"), "blocks" to Value.Arr(block.blocks.map { encodeBlock(it) })),
        )
        is RichTextBlock.ListBlock -> Value.Obj(
            listOf(
                "type" to Value.Str("list"),
                "ordered" to Value.Bool(block.ordered),
                "start" to Value.Integer(block.start),
                "tight" to Value.Bool(block.tight),
                "items" to Value.Arr(block.items.map { item -> Value.Arr(item.map { encodeBlock(it) }) }),
            ),
        )
        RichTextBlock.ThematicBreak -> Value.Obj(listOf("type" to Value.Str("thematicBreak")))
        is RichTextBlock.Table -> Value.Obj(
            listOf(
                "type" to Value.Str("table"),
                "headers" to Value.Arr(block.headers.map { encodeInlines(it) }),
                "alignments" to Value.Arr(block.alignments.map { Value.Str(alignmentName(it)) }),
                "rows" to Value.Arr(block.rows.map { row -> Value.Arr(row.map { encodeInlines(it) }) }),
            ),
        )
    }

    private fun encodeInlines(inlines: List<RichTextInline>): Value =
        Value.Arr(inlines.map { encodeInline(it) })

    private fun encodeInline(inline: RichTextInline): Value = when (inline) {
        is RichTextInline.Text -> Value.Obj(listOf("type" to Value.Str("text"), "value" to Value.Str(inline.value)))
        is RichTextInline.Emphasis -> Value.Obj(listOf("type" to Value.Str("emphasis"), "children" to encodeInlines(inline.children)))
        is RichTextInline.Strong -> Value.Obj(listOf("type" to Value.Str("strong"), "children" to encodeInlines(inline.children)))
        is RichTextInline.Strikethrough -> Value.Obj(listOf("type" to Value.Str("strikethrough"), "children" to encodeInlines(inline.children)))
        is RichTextInline.Code -> Value.Obj(listOf("type" to Value.Str("code"), "value" to Value.Str(inline.value)))
        is RichTextInline.Link -> Value.Obj(listOf("type" to Value.Str("link"), "text" to encodeInlines(inline.text), "url" to Value.Str(inline.url)))
        is RichTextInline.Image -> Value.Obj(listOf("type" to Value.Str("image"), "alt" to Value.Str(inline.alt), "url" to Value.Str(inline.url)))
        RichTextInline.LineBreak -> Value.Obj(listOf("type" to Value.Str("lineBreak")))
    }

    private fun alignmentName(a: RichTextColumnAlignment): String = when (a) {
        RichTextColumnAlignment.NONE -> "none"
        RichTextColumnAlignment.LEFT -> "left"
        RichTextColumnAlignment.CENTER -> "center"
        RichTextColumnAlignment.RIGHT -> "right"
    }
}
