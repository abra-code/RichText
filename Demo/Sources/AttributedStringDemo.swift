// Demo/Sources/AttributedStringDemo.swift
//
// Demonstrates initializing RichText from an AttributedString / NSAttributedString from three sources -
// Markdown, RTF, and HTML - each shown via the path that suits it:
//
//   - Markdown: RichText(introspecting:) reconstructs the document MODEL from the AttributedString by reading
//     its presentation intents (RichTextDocument(attributedString:)). Foundation's Markdown parser fills
//     those intents, so structure - headings, lists, quotes, GFM tables - comes back as real model blocks,
//     which then get the draw-only decorations and table-aware copy.
//   - RTF / HTML: RichText(attributed:) paints the NSAttributedString as-is, so the source's own fonts /
//     styling render directly. (Introspection is NOT used for these: RTF / HTML decoded by NSAttributedString
//     carry font attributes, not presentation intents, so introspection would only recover plain paragraphs.
//     See RichTextAttributedStringImporter's notes.)

import SwiftUI
import RichText

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

enum AttributedSource: String, CaseIterable, Identifiable {
    case markdown, rtf, html
    var id: String { rawValue }
    var title: String {
        switch self {
        case .markdown: return "Markdown"
        case .rtf: return "RTF"
        case .html: return "HTML"
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

    // Decoded once per view instance (NSAttributedString RTF / HTML decoding is main-thread work; the
    // snippets are tiny). Held as plain stored properties - a SwiftUI View need not be Sendable.
    private let markdownDocument: RichTextDocument
    private let rtfString: NSAttributedString
    private let htmlString: NSAttributedString

    init() {
        let attributed = (try? AttributedString(
            markdown: sampleMarkdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        )) ?? AttributedString(sampleMarkdown)
        markdownDocument = RichTextDocument(attributedString: attributed)
        rtfString = Self.decode(sampleRTF, .rtf)
        htmlString = Self.decode(sampleHTML, .html)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                rendered

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
            Picker("Source", selection: $source) {
                ForEach(AttributedSource.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()
            .background(.regularMaterial)
        }
        .safeAreaInset(edge: .bottom) {
            // Copy is available only for the introspected Markdown model (the table-aware serializers need the
            // model; RTF / HTML here are rendered as-is with no reconstructed model).
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

    // Each source rendered via its appropriate initializer. Each `switch` branch is its own SwiftUI
    // identity, so switching sources tears down one text view and builds another.
    @ViewBuilder
    private var rendered: some View {
        switch source {
        case .markdown: RichText(markdownDocument)          // introspected model -> full structure + decorations
        case .rtf: RichText(attributed: rtfString)          // native RTF styling, as-is
        case .html: RichText(attributed: htmlString)        // native HTML styling, as-is
        }
    }

    private var sourceText: String {
        switch source {
        case .markdown: return sampleMarkdown
        case .rtf: return sampleRTF
        case .html: return sampleHTML
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
        }
    }

    private static func decode(_ string: String, _ type: NSAttributedString.DocumentType) -> NSAttributedString {
        guard let data = string.data(using: .utf8) else {
            return NSAttributedString(string: string)
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: type,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        return (try? NSAttributedString(data: data, options: options, documentAttributes: nil))
            ?? NSAttributedString(string: string)
    }
}
