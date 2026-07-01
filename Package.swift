// swift-tools-version: 6.0
//
// RichTextView - a high-fidelity, dependency-free rich-text DISPLAY component that renders a whole
// document (headings, code blocks, quotes, lists, GFM tables, inline styling, links) into ONE native
// text view, so the entire document is selectable and copyable as a single unit. Cross-platform
// (iOS / iPadOS / macOS / visionOS) on TextKit 2, with table-aware copy serialization (RTF / HTML /
// Markdown) so content round-trips off iOS even though iOS TextKit has no native table model.
//
// See Private/ios-richtext-view-design.md for the investigation and the phased plan (P0-P6).

import PackageDescription

let package = Package(
    name: "RichTextView",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "RichTextView", targets: ["RichTextView"]),
        .library(name: "AsyncImageCache", targets: ["AsyncImageCache"]),
    ],
    targets: [
        .target(name: "RichTextView", dependencies: ["AsyncImageCache"]),
        .testTarget(name: "RichTextViewTests", dependencies: ["RichTextView"]),
        .target(name: "AsyncImageCache", path: "Sources/AsyncImageCache", exclude: ["README.md"]),
        .testTarget(
            name: "AsyncImageCacheTests",
            dependencies: ["AsyncImageCache"],
            path: "Tests/AsyncImageCacheTests"
        ),
    ]
)
