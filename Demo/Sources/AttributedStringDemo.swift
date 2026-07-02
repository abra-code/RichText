// Demo/Sources/AttributedStringDemo.swift
//
// Demonstrates initializing RichText from an AttributedString / NSAttributedString from five sources -
// inline Markdown / RTF / HTML snippets, plus two richer documents loaded from the app bundle - each
// shown via the path that suits it:
//
//   - Markdown: RichText(introspecting:) reconstructs the document MODEL from the AttributedString by reading
//     its presentation intents (RichTextDocument(attributedString:)). Foundation's Markdown parser fills
//     those intents, so structure - headings, lists, quotes, GFM tables - comes back as real model blocks,
//     which then get the draw-only decorations and table-aware copy.
//   - RTF / HTML (inline or file): RichText(attributed:) paints the NSAttributedString as-is, so the source's
//     own fonts / styling render directly. (Introspection is NOT used for these: RTF / HTML decoded by
//     NSAttributedString carry font attributes, not presentation intents, so introspection would only recover
//     plain paragraphs. See RichTextAttributedStringImporter's notes.)
//
// The bundle documents (TypographyTour.rtf, Showcase.html) tour the TextKit-only features - NSTextTable,
// text lists, alignment / indents / line spacing, underline styles, highlights, shadow, outline, kerning,
// superscript, embedded image attachments. Two extra controls make the point:
//   - an Engine picker (TextKit 1 / TextKit 2). Note that for NSTextTable content a TextKit 2 NSTextView
//     silently downgrades itself to TextKit 1, so tables render natively either way on macOS.
//   - a "SwiftUI Text" comparison toggle that renders the SAME attributed string in a plain Text view,
//     which drops tables, attachments, and all paragraph styling.

import SwiftUI
import RichText

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

enum AttributedSource: String, CaseIterable, Identifiable {
    case markdown, rtf, html, rtfFile, htmlFile
    var id: String { rawValue }
    var title: String {
        switch self {
        case .markdown: return "Markdown"
        case .rtf: return "RTF"
        case .html: return "HTML"
        case .rtfFile: return "RTF file"
        case .htmlFile: return "HTML file"
        }
    }
}

// MARK: - Sample content

private let sampleMarkdown = """
# Introspected from Markdown

Foundation parses this Markdown into a **structured** `AttributedString`; `RichText(introspecting:)` walks \
its presentation intents back into the document *model*.

- lists come through
- **inline** styles too
- and a [link](https://swift.org)

> Block quotes as well.

| Feature  | Recovered |
| :------- | :-------: |
| Headings |    yes    |
| Tables   |    yes    |
"""

// Minimal, valid RTF (bold heading + a styled paragraph) so NSAttributedString can decode it.
private let sampleRTF = #"""
{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\fswiss Helvetica;}}
\f0\fs36\b RTF heading\b0\fs24\par
A paragraph with \b bold\b0 , \i italic\i0 , and plain text - decoded by NSAttributedString.\par
A second paragraph.\par}
"""#

private let sampleHTML = """
<h1>HTML heading</h1>
<p>A paragraph with <b>bold</b>, <i>italic</i>, and a <a href="https://swift.org">link</a>.</p>
<ul><li>first item</li><li>second item</li></ul>
<blockquote>A quoted line.</blockquote>
"""

// MARK: - View

struct AttributedStringDemoView: View {
    static let windowID = "attributed-string"

    @State private var source: AttributedSource = .markdown
    @State private var engine: RichTextEngine = .textKit1
    @State private var compareWithText = false

    // Decoded once per view instance (NSAttributedString RTF / HTML decoding is main-thread work; even the
    // bundle documents are small). Held as plain stored properties - a SwiftUI View need not be Sendable.
    private let markdownAttributed: AttributedString
    private let markdownDocument: RichTextDocument
    private let rtfString: NSAttributedString
    private let htmlString: NSAttributedString
    private let rtfFileString: NSAttributedString
    private let htmlFileString: NSAttributedString
    private let rtfFileSource: String
    private let htmlFileSource: String

    init() {
        let attributed = (try? AttributedString(
            markdown: sampleMarkdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        )) ?? AttributedString(sampleMarkdown)
        markdownAttributed = attributed
        markdownDocument = RichTextDocument(attributedString: attributed)
        rtfString = Self.decode(sampleRTF, .rtf)
        htmlString = Self.decode(sampleHTML, .html)
        (rtfFileString, rtfFileSource) = Self.decodeBundleFile("TypographyTour", "rtf", .rtf)
        (htmlFileString, htmlFileSource) = Self.decodeBundleFile("Showcase", "html", .html)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                rendered
                    // `id` rebuilds the representable when the engine OR source changes: the engine swaps the
                    // whole text-view backend (TextKit 1 <-> TextKit 2), and a source swap under TextKit 2
                    // must not reuse a fragment layout built for different content.
                    .id("\(source.rawValue)-\(engine)")

                if compareWithText {
                    comparison
                }

                DisclosureGroup("Source") {
                    Text(sourceText)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .font(.callout)
            }
            .padding()
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 8) {
                Picker("Source", selection: $source) {
                    ForEach(AttributedSource.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                HStack {
                    Picker("Engine", selection: $engine) {
                        Text("TextKit 1").tag(RichTextEngine.textKit1)
                        Text("TextKit 2").tag(RichTextEngine.textKit2)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                    Spacer()
                    Toggle("SwiftUI Text", isOn: $compareWithText)
                        .help("Render the same attributed string in a plain SwiftUI Text view for comparison")
                }
            }
            .padding()
            .background(.regularMaterial)
        }
        .safeAreaInset(edge: .bottom) {
            // Copy is available only for the introspected Markdown model (the table-aware serializers need the
            // model; the RTF / HTML sources are rendered as-is with no reconstructed model).
            if source == .markdown {
                Button {
                    RichTextPasteboard.write(markdownDocument)
                } label: {
                    Label("Copy model as rich text", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                        .padding(8)
                }
                .buttonStyle(.borderedProminent)
                .padding()
                .background(.regularMaterial)
            }
        }
    }

    // Each source rendered via its appropriate initializer.
    @ViewBuilder
    private var rendered: some View {
        switch source {
        case .markdown: RichText(markdownDocument, engine: engine)      // introspected model -> full structure + decorations
        case .rtf: RichText(attributed: rtfString, engine: engine)      // native RTF styling, as-is
        case .html: RichText(attributed: htmlString, engine: engine)    // native HTML styling, as-is
        case .rtfFile: RichText(attributed: rtfFileString, engine: engine)
        case .htmlFile: RichText(attributed: htmlFileString, engine: engine)
        }
    }

    // The SAME content in a plain SwiftUI Text view. Text reads only SwiftUI-scope attributes, so the
    // AppKit / UIKit attributes a decoded NSAttributedString carries (fonts, colors, paragraph styles,
    // tables, attachments) are largely dropped - which is exactly the capability gap this demonstrates.
    private var comparison: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("The same attributed string in SwiftUI Text:")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(comparisonAttributed)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var comparisonAttributed: AttributedString {
        switch source {
        case .markdown: return markdownAttributed
        case .rtf: return AttributedString(rtfString)
        case .html: return AttributedString(htmlString)
        case .rtfFile: return AttributedString(rtfFileString)
        case .htmlFile: return AttributedString(htmlFileString)
        }
    }

    private var sourceText: String {
        switch source {
        case .markdown: return sampleMarkdown
        case .rtf: return sampleRTF
        case .html: return sampleHTML
        case .rtfFile: return rtfFileSource
        case .htmlFile: return htmlFileSource
        }
    }

    private var explanation: String {
        switch source {
        case .markdown:
            return "Markdown -> AttributedString(.full) -> RichText(introspecting:). Presentation intents are recovered as real model blocks, so the heading, list, quote, and table (with the drawn grid) all come back - and \"Copy model as rich text\" emits a real table."
        case .rtf:
            return "RTF -> NSAttributedString -> RichText(attributed:). The RTF's own fonts and styling render directly. (Introspection is not used here: RTF carries font attributes, not presentation intents, so it would only recover plain paragraphs.)"
        case .html:
            return "HTML -> NSAttributedString -> RichText(attributed:). NSAttributedString's HTML importer renders the markup with its own styling. (Like RTF, HTML has no presentation intents to introspect.)"
        case .rtfFile:
            return "TypographyTour.rtf (bundle) -> NSAttributedString -> RichText(attributed:). A tour of TextKit-only typography: a real NSTextTable (macOS renders it natively - for table content a TextKit 2 view silently falls back to TextKit 1), text lists, alignment / indents / line spacing, underline styles, highlight, shadow, outline, kerning, superscript. Toggle SwiftUI Text to see how much a plain Text view drops."
        case .htmlFile:
            return "Showcase.html (bundle) -> NSAttributedString (WebKit importer) -> RichText(attributed:). CSS colors and highlights, serif / monospace faces, per-paragraph alignment, lists, a block quote, a real table, and an image embedded as a data: URI that becomes a rendered text attachment."
        }
    }

    private static func decode(_ string: String, _ type: NSAttributedString.DocumentType) -> NSAttributedString {
        guard let data = string.data(using: .utf8) else {
            return NSAttributedString(string: string)
        }
        return decode(data, type) ?? NSAttributedString(string: string)
    }

    /// Loads and decodes a bundled document, returning the attributed string and (for the Source disclosure)
    /// the raw file text, truncated so a 30 KB HTML file with an embedded image stays readable.
    private static func decodeBundleFile(_ name: String, _ ext: String,
                                         _ type: NSAttributedString.DocumentType) -> (NSAttributedString, String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let data = try? Data(contentsOf: url) else {
            return (NSAttributedString(string: "\(name).\(ext) is missing from the app bundle."), "")
        }
        let decoded = decode(data, type) ?? NSAttributedString(string: "\(name).\(ext) failed to decode.")
        var raw = String(data: data, encoding: .utf8) ?? ""
        let limit = 1500
        if raw.count > limit {
            raw = String(raw.prefix(limit)) + "\n... (\(data.count) bytes total)"
        }
        return (decoded, raw)
    }

    private static func decode(_ data: Data, _ type: NSAttributedString.DocumentType) -> NSAttributedString? {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: type,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        return try? NSAttributedString(data: data, options: options, documentAttributes: nil)
    }
}
