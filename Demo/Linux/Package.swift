// swift-tools-version: 6.0
//
// The RichText demo for Linux: a GTK 4 window with a sample document, local and remote images, the Markdown
// fixtures, the find bar, the remote-image policy and "Copy as Rich Text". Linux only; the Apple demo is the
// Xcode project beside it.
//
//   cd Demo/Linux && swift run RichTextDemo
//   swift run RichTextDemo --document tables        (opens that document first, by its name in the menu)
//   swift run RichTextDemo --screenshot /tmp/demo.png    (saves the window as a PNG, then quits)

import PackageDescription

let package = Package(
    name: "RichTextDemo",
    dependencies: [
        .package(name: "RichText", path: "../.."),
    ],
    targets: [
        .systemLibrary(name: "CDemoGtk", pkgConfig: "gtk4"),
        .executableTarget(
            name: "RichTextDemo",
            dependencies: ["CDemoGtk", .product(name: "RichText", package: "RichText")]
        ),
    ]
)
