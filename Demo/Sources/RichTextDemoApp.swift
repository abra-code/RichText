// Demo/Sources/RichTextDemoApp.swift
//
// A minimal multiplatform app to verify RichTextView on iOS and macOS: it renders a rich sample
// document in one selectable text view, and offers "Copy as rich text" (RichTextPasteboard) so the
// table-aware RTF / HTML / Markdown copy can be pasted into TextEdit / Notes / a browser.

import SwiftUI
import RichTextView

@main
struct RichTextDemoApp: App {
    var body: some Scene {
        WindowGroup {
            DemoView()
        }
    }
}

private let sampleMarkdown = """
# RichTextView

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
    @State private var engine: RichTextEngine = .textKit1

    var body: some View {
        ScrollView {
            // `id(engine)` rebuilds the representable when the engine changes, so switching swaps the
            // whole text-view backend (TextKit 1 <-> TextKit 2) for a like-for-like comparison.
            RichTextView(document, engine: engine)
                .padding()
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .id(engine)
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
