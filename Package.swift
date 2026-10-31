// swift-tools-version: 6.0
//
// RichText - a high-fidelity, dependency-free rich-text DISPLAY component that renders a whole
// document (headings, code blocks, quotes, lists, GFM tables, inline styling, links) into ONE native
// text view, so the entire document is selectable and copyable as a single unit. Cross-platform
// (iOS / iPadOS / macOS / visionOS) on TextKit 2, with table-aware copy serialization (RTF / HTML /
// Markdown) so content round-trips off iOS even though iOS TextKit has no native table model.
//
// On Linux the same RichText module is built from the platform-independent layers: the document model,
// the Markdown parser and autolinker, the URL policy, the Markdown and HTML serializers, the syntax
// highlighter's tokenizer and the accessibility text, over FoundationEssentials only, plus a GTK 4 renderer
// (Gtk/: the document in one GtkTextView). The Apple renderer (TextKit, SwiftUI, AppKit/UIKit) and the RTF
// serializer are not compiled; GTK programs take HTML.
//
// See Private/ios-richtext-view-design.md for the investigation and the phased plan (P0-P6).

import PackageDescription

#if os(Linux)
import Foundation

// Every path under `target` except those in `kept` and the folders that lead to them: an exclude list that
// leaves only `kept` in the target, so a new Apple-only file needs no change here.
func excludingAllBut(_ kept: [String], in target: String) -> [String] {
    let root = Context.packageDirectory + "/" + target
    func walk(_ relative: String) -> [String] {
        let folder = relative.isEmpty ? root : root + "/" + relative
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        var excluded: [String] = []
        for entry in entries.sorted() {
            let path = relative.isEmpty ? entry : relative + "/" + entry
            if kept.contains(path) {
                continue
            }
            if kept.contains(where: { $0.hasPrefix(path + "/") }) {
                excluded += walk(path)
            } else {
                excluded.append(path)
            }
        }
        return excluded
    }
    return walk("")
}

// The platform-independent sources and the GTK renderer (Gtk/), the only ones built on Linux.
let portableSources = [
    "Gtk",
    "Markdown",
    "Model/RichTextDocument+BaseURL.swift",
    "Model/RichTextModel.swift",
    "Model/RichTextTheme.swift",
    "Rendering/RichTextAccessibility.swift",
    "Rendering/RichTextImagePlaceholder.swift",
    "Rendering/RichTextSyntaxTokenizer.swift",
    "RichTextURLPolicy.swift",
    "Search/RichTextSearchOptions.swift",
    "Serialization/RichTextHTMLSerializer.swift",
    "Serialization/RichTextInlineImage.swift",
    "Serialization/RichTextMarkdownSerializer.swift",
]
// The tests of those sources (their Apple-only cases are behind #if !os(Linux)) and of the GTK renderer.
let portableTests = [
    "Gtk",
    "RichTextAccessibilityTests.swift",
    "RichTextBaseURLTests.swift",
    "RichTextFixtureEmitterTests.swift",
    "RichTextMarkdownParserTests.swift",
    "RichTextSearchTests.swift",
    "RichTextSerializerTests.swift",
    "RichTextSyntaxHighlighterTests.swift",
    "RichTextURLPolicyTests.swift",
]

let package = Package(
    name: "RichText",
    products: [
        .library(name: "RichText", targets: ["RichText"]),
    ],
    dependencies: [
        // The image loader and cache; 0.2.0 is its first version with the Linux port.
        .package(url: "https://github.com/abra-code/AsyncImageCache", from: "0.2.0"),
    ],
    targets: [
        // GTK 4's C API (GtkTextView, GtkTextBuffer, Pango), for the renderer.
        .systemLibrary(name: "CRichTextGtk", pkgConfig: "gtk4"),
        .target(
            name: "RichText",
            dependencies: ["CRichTextGtk", .product(name: "AsyncImageCache", package: "AsyncImageCache")],
            exclude: excludingAllBut(portableSources, in: "Sources/RichText"),
            sources: portableSources
        ),
        .testTarget(
            name: "RichTextTests",
            dependencies: ["RichText", "CRichTextGtk"],
            exclude: excludingAllBut(portableTests, in: "Tests/RichTextTests"),
            sources: portableTests
        ),
    ]
)
#else
let package = Package(
    name: "RichText",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "RichText", targets: ["RichText"]),
    ],
    dependencies: [
        // AsyncImageCache lives in its own repo, consumed as a versioned release.
        .package(url: "https://github.com/abra-code/AsyncImageCache", from: "0.1.0"),
    ],
    targets: [
        .target(
            name: "RichText",
            dependencies: [.product(name: "AsyncImageCache", package: "AsyncImageCache")],
            exclude: ["Gtk"]   // the Linux renderer
        ),
        .testTarget(name: "RichTextTests", dependencies: ["RichText"], exclude: ["Gtk"]),
    ]
)
#endif
