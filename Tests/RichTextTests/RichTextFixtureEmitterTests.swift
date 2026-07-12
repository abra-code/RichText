// Tests/RichTextTests/RichTextFixtureEmitterTests.swift
//
// Stage C - cross-platform parity fixtures. The Swift parser is NORMATIVE, so it EMITS the shared fixture
// set that the Kotlin JVM tests then assert against (android/.../RichTextFixtureParityTest.kt). For every
// `Fixtures/markdown/*.md` this writes two siblings under `Fixtures/expected/`:
//   <name>.json  - the parse tree as canonical, deterministic JSON (schema below)
//   <name>.html  - RichTextHTMLSerializer.fragment(from:) output (byte-for-byte)
// The Kotlin side re-derives both from its own port and compares byte-for-byte; any parser or serializer
// drift between the two platforms fails there.
//
// Two modes, selected by the RICHTEXT_EMIT_FIXTURES environment variable:
//   set   -> EMIT: (re)write the expected files from the current Swift output.
//   unset -> VERIFY: assert the on-disk fixtures still match current Swift output (guards Swift-side drift;
//            this is what a normal `swift test` run does).
// Regenerate with:  RICHTEXT_EMIT_FIXTURES=1 swift test --filter RichTextFixtureEmitterTests
//
// The canonical JSON is hand-rolled (not JSONEncoder) so its key order, escaping, and 2-space indentation
// are fixed and reproducible identically in Kotlin. Escaping is minimal-JSON: only ", \\, and C0 control
// chars are escaped; every other character (including non-ASCII) passes through literally, so the UTF-8
// bytes are identical regardless of Swift's Unicode-scalar vs Kotlin's UTF-16 internal iteration.

import XCTest
import Foundation
@testable import RichText

final class RichTextFixtureEmitterTests: XCTestCase {

    func testEmitOrVerifyFixtures() throws {
        let fixtures = Self.fixturesDirectory()
        let markdownDir = fixtures.appendingPathComponent("markdown", isDirectory: true)
        let expectedDir = fixtures.appendingPathComponent("expected", isDirectory: true)

        let names = try Self.markdownFixtureNames(in: markdownDir)
        XCTAssertFalse(names.isEmpty, "no *.md fixtures found under \(markdownDir.path)")

        let emitting = ProcessInfo.processInfo.environment["RICHTEXT_EMIT_FIXTURES"] != nil
        if emitting {
            try FileManager.default.createDirectory(at: expectedDir, withIntermediateDirectories: true)
        }

        for name in names {
            let source = try String(contentsOf: markdownDir.appendingPathComponent(name + ".md"), encoding: .utf8)
            let blocks = RichTextMarkdownParser.parse(source)
            let json = FixtureJSON.canonical(blocks)
            let html = RichTextHTMLSerializer.fragment(from: RichTextDocument(blocks: blocks))

            let jsonURL = expectedDir.appendingPathComponent(name + ".json")
            let htmlURL = expectedDir.appendingPathComponent(name + ".html")

            if emitting {
                try json.write(to: jsonURL, atomically: true, encoding: .utf8)
                try html.write(to: htmlURL, atomically: true, encoding: .utf8)
            } else {
                let expectedJSON = try String(contentsOf: jsonURL, encoding: .utf8)
                let expectedHTML = try String(contentsOf: htmlURL, encoding: .utf8)
                XCTAssertEqual(json, expectedJSON, "parse-tree JSON drift for \(name) (regenerate with RICHTEXT_EMIT_FIXTURES=1)")
                XCTAssertEqual(html, expectedHTML, "HTML drift for \(name) (regenerate with RICHTEXT_EMIT_FIXTURES=1)")
            }
        }
    }

    // Repo root is three directories up from this source file: Tests/RichTextTests/<this>.swift -> repo root.
    private static func fixturesDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RichTextTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    private static func markdownFixtureNames(in directory: URL) throws -> [String] {
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return entries
            .filter { $0.pathExtension == "md" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }
}

// MARK: - Canonical JSON (mirrors android/.../RichTextFixtureParityTest.kt FixtureJson byte-for-byte)

private enum FixtureJSON {

    /// The parse tree (an array of blocks) rendered as canonical JSON with a trailing newline.
    static func canonical(_ blocks: [RichTextBlock]) -> String {
        render(.array(blocks.map(encode(block:))), 0) + "\n"
    }

    // A tiny ordered JSON tree so all formatting lives in one `render` function that is trivial to mirror.
    private indirect enum Value {
        case object([(String, Value)])   // insertion-ordered; NEVER sorted
        case array([Value])
        case string(String)
        case integer(Int)
        case boolean(Bool)
        case null
    }

    private static func render(_ value: Value, _ indent: Int) -> String {
        switch value {
        case .string(let s): return quoted(s)
        case .integer(let n): return String(n)
        case .boolean(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let items):
            if items.isEmpty { return "[]" }
            let pad = String(repeating: "  ", count: indent + 1)
            let close = String(repeating: "  ", count: indent)
            let body = items.map { pad + render($0, indent + 1) }.joined(separator: ",\n")
            return "[\n" + body + "\n" + close + "]"
        case .object(let pairs):
            if pairs.isEmpty { return "{}" }
            let pad = String(repeating: "  ", count: indent + 1)
            let close = String(repeating: "  ", count: indent)
            let body = pairs.map { pad + quoted($0.0) + ": " + render($0.1, indent + 1) }.joined(separator: ",\n")
            return "{\n" + body + "\n" + close + "}"
        }
    }

    // Minimal JSON string escaping. Iterates Unicode scalars so the special cases (all ASCII) match Kotlin's
    // per-char iteration; non-ASCII scalars pass through literally -> identical UTF-8 on both platforms.
    private static func quoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    // MARK: node -> Value (fixed key order; must match the Kotlin encoder exactly)

    private static func encode(block: RichTextBlock) -> Value {
        switch block {
        case .heading(let level, let inlines):
            return .object([("type", .string("heading")), ("level", .integer(level)), ("inlines", encode(inlines: inlines))])
        case .paragraph(let inlines):
            return .object([("type", .string("paragraph")), ("inlines", encode(inlines: inlines))])
        case .codeBlock(let language, let code):
            return .object([("type", .string("codeBlock")), ("language", language.map(Value.string) ?? .null), ("code", .string(code))])
        case .blockQuote(let blocks):
            return .object([("type", .string("blockQuote")), ("blocks", .array(blocks.map(encode(block:))))])
        case .list(let ordered, let start, let tight, let items):
            return .object([
                ("type", .string("list")),
                ("ordered", .boolean(ordered)),
                ("start", .integer(start)),
                ("tight", .boolean(tight)),
                ("items", .array(items.map { .array($0.map(encode(block:))) })),
            ])
        case .thematicBreak:
            return .object([("type", .string("thematicBreak"))])
        case .table(let headers, let alignments, let rows):
            return .object([
                ("type", .string("table")),
                ("headers", .array(headers.map(encode(inlines:)))),
                ("alignments", .array(alignments.map { Value.string(alignmentName($0)) })),
                ("rows", .array(rows.map { .array($0.map(encode(inlines:))) })),
            ])
        }
    }

    private static func encode(inlines: [RichTextInline]) -> Value {
        .array(inlines.map(encode(inline:)))
    }

    private static func encode(inline: RichTextInline) -> Value {
        switch inline {
        case .text(let s):
            return .object([("type", .string("text")), ("value", .string(s))])
        case .emphasis(let c):
            return .object([("type", .string("emphasis")), ("children", encode(inlines: c))])
        case .strong(let c):
            return .object([("type", .string("strong")), ("children", encode(inlines: c))])
        case .strikethrough(let c):
            return .object([("type", .string("strikethrough")), ("children", encode(inlines: c))])
        case .code(let s):
            return .object([("type", .string("code")), ("value", .string(s))])
        case .link(let text, let url):
            return .object([("type", .string("link")), ("text", encode(inlines: text)), ("url", .string(url))])
        case .image(let alt, let url):
            return .object([("type", .string("image")), ("alt", .string(alt)), ("url", .string(url))])
        case .lineBreak:
            return .object([("type", .string("lineBreak"))])
        }
    }

    private static func alignmentName(_ a: RichTextColumnAlignment) -> String {
        switch a {
        case .none: return "none"
        case .left: return "left"
        case .center: return "center"
        case .right: return "right"
        }
    }
}
