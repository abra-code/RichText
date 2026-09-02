// Demo/Sources/RichTextDemoApp.swift
//
// A minimal multiplatform app to verify RichText on iOS and macOS: it renders a rich sample
// document in one selectable text view, and offers "Copy as rich text" (RichTextPasteboard) so the
// table-aware RTF / HTML / Markdown copy can be pasted into TextEdit / Notes / a browser.

import SwiftUI
import RichText

@main
struct RichTextDemoApp: App {
    var body: some Scene {
        WindowGroup {
            // macOS gets the attributed-string demo as its own window (below); iOS / iPadOS, where per-window
            // scenes do not apply on iPhone, reaches it through a tab.
            #if os(macOS)
            DemoView()
            #else
            RootTabView()
            #endif
        }

        #if os(macOS)
        // A second, real window for the attributed-string demo. It also opens from the menu (Cmd-Shift-2).
        Window("Attributed String", id: AttributedStringDemoView.windowID) {
            AttributedStringDemoView()
        }
        .commands {
            AttributedStringWindowCommands()
        }
        #endif
    }
}

#if os(macOS)
private struct AttributedStringWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Attributed String Window") {
                openWindow(id: AttributedStringDemoView.windowID)
            }
            .keyboardShortcut("2", modifiers: [.command, .shift])
        }
    }
}
#else
private struct RootTabView: View {
    var body: some View {
        TabView {
            DemoView()
                .tabItem { Label("Markdown", systemImage: "doc.richtext") }
            AttributedStringDemoView()
                .tabItem { Label("Attributed", systemImage: "textformat") }
        }
    }
}
#endif

private let sampleMarkdown = """
# RichText

A whole document rendered in **one** selectable text view - select and copy across *everything*,
including the table.

## Inline

`inline code`, **bold**, *italic*, ~~strikethrough~~, and an explicit [link](https://www.swift.org).

A bare URL autolinks too: visit https://swift.org or www.apple.com for more.

Reference-style links: the [Swift forums][forums] and [docs] (a shortcut reference).

## Image

An image loads asynchronously (placeholder first, then the picture):

![Swift logo](https://www.swift.org/apple-touch-icon.png)

## Lists

- first item
- second item with `code`
- nested:
  - sub one
  - sub two

1. ordered one
2. ordered two

## Quote

> A block quote, with a bar in the gutter and a **bold** word.

## Code

```swift
// Greet someone by name.
func greet(_ name: String) -> String {
    let count = 42
    return "Hello, \\(name)!"
}
```

## Table

Toggle the engine to compare table rendering. The Notes column is long on purpose, so wrapping (or the
lack of it) is visible.

| Feature  | Status | Notes                                                                    |
| -------- | :----: | ------------------------------------------------------------------------ |
| Headings |   ok   | scaled and bold, following the system text style                          |
| Code     |   ok   | rounded background card, now with syntax highlighting and Dynamic Type    |
| Tables   | ok-ish but really long and at some point it should wrap | wrapping cells need a custom TextKit 2 layout fragment - this note is deliberately long so it has to wrap onto multiple lines |

---

[forums]: https://forums.swift.org
[docs]: https://swift.org/documentation

That is all.
"""

struct DemoView: View {
    private let document = RichTextDocument(markdown: sampleMarkdown)
    // Rendered once per engine, not in `body`: the find controller publishes on every keystroke, which
    // re-runs this body, and re-rendering the Markdown each time would be pure waste.
    private let rendered: [RichTextEngine: NSAttributedString] = [
        .textKit1: RichTextAttributedString.make(RichTextDocument(markdown: sampleMarkdown), engine: .textKit1),
        .textKit2: RichTextAttributedString.make(RichTextDocument(markdown: sampleMarkdown), engine: .textKit2),
    ]
    @State private var engine: RichTextEngine = .textKit1
    // The find bar (Cmd-F) over this one document: the controller holds the query and cursor,
    // `RichText.find(_:)` paints its matches, `richTextFindBar` shows the bar and installs the shortcut.
    @StateObject private var find = RichTextFindController()

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    // `id(engine)` rebuilds the representable when the engine changes, so switching swaps the
                    // whole text-view backend (TextKit 1 <-> TextKit 2) for a like-for-like comparison.
                    RichText(attributed: rendered[engine]!, engine: engine)
                        .find(find)
                        .padding()
                        .frame(maxWidth: 720)
                        .frame(maxWidth: .infinity)
                        .id(engine)
                        // Scroll the current match into view. The anchor is resolved here, in the CONTENT's
                        // coordinate space (this overlay covers the document, not the viewport), so the
                        // match's vertical fraction of the content is what scrollTo's UnitPoint wants;
                        // whether it is already visible is decided against the scroll view's frame.
                        .overlayPreferenceValue(RichTextCurrentMatchAnchorKey.self) { anchor in
                            GeometryReader { content in
                                let rect = anchor.map { content[$0] }
                                Color.clear
                                    .onChange(of: rect) { rect in
                                        guard let rect, content.size.height > 0 else { return }
                                        let inScroll = content.frame(in: .named("scroll"))
                                        let top = inScroll.minY + rect.minY
                                        let bottom = inScroll.minY + rect.maxY
                                        if top < 0 || bottom > viewport.size.height {
                                            let fraction = max(0, min(1, rect.midY / content.size.height))
                                            withAnimation { proxy.scrollTo(engine, anchor: UnitPoint(x: 0, y: fraction)) }
                                        }
                                    }
                            }
                            .allowsHitTesting(false)
                        }
                }
                .coordinateSpace(name: "scroll")
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("Engine", selection: $engine) {
                Text("TextKit 1").tag(RichTextEngine.textKit1)
                Text("TextKit 2").tag(RichTextEngine.textKit2)
            }
            .pickerStyle(.segmented)
            .padding()
            .background(.regularMaterial)
        }
        .richTextFindBar(find)
        .safeAreaInset(edge: .bottom) {
            Button {
                RichTextPasteboard.write(document)
            } label: {
                Label("Copy as rich text", systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity)
                    .padding(8)
            }
            .buttonStyle(.borderedProminent)
            .padding()
            .background(.regularMaterial)
        }
    }
}
