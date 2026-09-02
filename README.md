# RichText

Cross-platform (iOS / iPadOS / macOS / visionOS) component that renders a whole rich
document - headings, paragraphs, code blocks, block quotes, lists, GFM tables, inline styling, links -
into **one native text view**, so the entire document is **selectable and copyable as a single unit**.
Copy is **table-aware** (RTF / HTML / Markdown) so content round-trips into TextEdit / Notes / Word even
though iOS TextKit has no native table model.  

Depends on [AsyncImageCache](https://github.com/abra-code/AsyncImageCache)  


## Usage

```swift
import RichText

// From Markdown:
RichText(markdown: "# Hello\n\nA **bold** word and a `code` span.")

// From the document model (build it however you like):
let doc = RichTextDocument(blocks: [.heading(level: 1, [.text("Hi")])])
RichText(doc)

// Copy the document as rich text (RTF table + HTML + Markdown) to the pasteboard:
RichTextPasteboard.write(doc)
```

`RichText` is read-only-but-selectable and self-sizes to its content for the proposed width, so it
drops into a `ScrollView` / `VStack` / a chat transcript directly. See `Demo/` for a runnable app.

## Find and highlight

Three layers, each usable without the one above it:

1. **Engine** (`RichTextSearch`, `RichTextPlainText`): pure functions. `RichTextSearch.matches(in:query:options:)` finds every hit in a string, an attributed string, or a document (rendered with the theme the view uses, so the ranges are the view's ranges), returning UTF-16 ranges in the rendered text plus a one-line snippet. Options: case, diacritics, whole word. `RichTextPlainText.text(for:)` is the document as the text a reader sees (alt text for images, table rows as comma-separated cells), for indexers that search many documents without rendering any.
2. **Highlights** (`RichText.findHighlights(_:)`): paints ranges behind the text and a distinct color on the current one. Draw-only on both engines (TextKit 1 paints in the layout manager's `drawBackground`, TextKit 2 uses rendering attributes), so a query change never re-lays-out the document. The current match's frame is published through `RichTextCurrentMatchAnchorKey` so an embedding scroller can bring it into view.
3. **Find bar** (`RichTextFindController`, `RichTextFindBar`): the standalone UI over one document. `RichText(doc).find(controller)` binds and paints; `.richTextFindBar(controller)` on the container shows the bar and installs Cmd-F, Cmd-G, Shift-Cmd-G and Escape.

A chat transcript takes layers 1 and 2 only: it runs the engine over every message, keeps one cross-message cursor of its own, and hands each message just its ranges.

## How it works

- **One model, one attributed string, one text view.** `RichTextDocument` (blocks + inline runs) is
  rendered by `RichTextAttributedString` into a single `NSAttributedString`, shown in an `NSTextView`
  (macOS) / `UITextView` (iOS).
- **Draw-only decorations.** The code-block rounded rectangle, block-quote bar, thematic-break hairline,
  and the table grid are PAINTED behind the text, keyed off semantic marker attributes. They add no block
  structure to the text, so selection / copy stay clean and the same string works on both platforms.
- **Two rendering engines, selectable side by side (`RichTextEngine`).** `.textKit1` paints decorations
  with a custom `NSLayoutManager` (`RichTextLayoutManager`); `.textKit2` paints them with a custom
  `NSTextLayoutFragment` (`RichTextLayoutFragment`) hosted in a TextKit 2 text view. They render
  identically except for tables (see status). Pick one at the call site: `RichText(doc, engine: .textKit2)`.
- **Serialization is decoupled from rendering.** `RichTextRTFSerializer` writes real RTF tables
  (`\trowd` / `\cellx` / `\cell` / `\row`), `RichTextHTMLSerializer` writes `<table>`, and
  `RichTextMarkdownSerializer` writes Markdown - so copy carries a real table even on iOS, where TextKit
  cannot render one. `RichTextPasteboard` puts all representations on the pasteboard at once.


## Rendering engines (TextKit 1 vs TextKit 2)

Both engines exist so the TextKit 2 path can be developed and compared against the proven TextKit 1 path.
They share everything below rendering (model, parser, serializers) and differ only in the rendering layer:

| | `.textKit1` (default) | `.textKit2` |
|---|---|---|
| Decoration painter | `RichTextLayoutManager` (`NSLayoutManager.drawBackground`) | `RichTextLayoutFragment` (`NSTextLayoutFragment.draw(at:in:)`) |
| Host | `NSTextView` / `UITextView` on an explicit TK1 stack | `NSTextView` (TK2 container) / `UITextView(usingTextLayoutManager:)` |
| Tables | macOS native `NSTextTable` (wrapping); iOS drawn grid (single-line) | drawn grid (single-line), both platforms |
| Layout | whole document laid out | viewport-based (the modern, streaming-friendly path) |

The demo's segmented control switches between them live. TextKit 2 is the strategic direction (and the
substrate for wrapping-cell tables); TextKit 1 remains the default until Strategy T2 lands.

## Key engineering decisions

- **Two engines, one model.** Because TextKit lives only in the rendering layer and copy is decoupled,
  the TextKit 2 backend was added as a parallel path (two files + an engine switch) rather than a rewrite;
  the model, parser, serializers, and tests are untouched and shared.
- **Draw-only decorations on both engines.** The same `.rtv*` marker attributes drive a custom
  `NSLayoutManager` (TK1) or a custom `NSTextLayoutFragment` (TK2); neither adds block structure, so
  selection and exported RTF stay clean.
- **Decouple copy from render.** Tables render per engine/platform, but copy ALWAYS goes through the
  serializer, so a copied table pastes as a real table everywhere.
- **No third-party dependencies.** The Markdown parser and all serializers are written from scratch.

## Verification

- `swift test` - 10 tests (parser + serializers), all pass.
- Library builds for macOS and iOS; the `Demo/` app builds for both.
- `Demo/` runs on the iOS simulator on BOTH engines: each launches cleanly and renders headings, inline
  styles, nested / ordered lists, the quote gutter bar, the rounded code card, the table (header tint +
  drawn grid), and the thematic-break hairline; the TextKit 2 decorations are not clipped (the custom
  fragment's `renderingSurfaceBounds` is grown to contain them). The macOS demo builds and launches on
  both engines (the macOS TextKit 2 `NSTextView` path runs without crashing). Still worth a manual pass:
  one-selection sweep across the whole document and copy -> paste a real table into TextEdit / Notes, on
  each engine.

### Note: the TextKit 1 stack must outlive the function that builds it

A TextKit 1 graph is rooted at the `NSTextStorage` (storage -> strong -> layout manager -> strong ->
container); the back-pointers `container.layoutManager` and `layoutManager.textStorage` are weak. The
text view holds only the container, so if nothing else retains the storage and layout manager they are
deallocated immediately, leaving `container.layoutManager == nil`. `UITextView(frame:textContainer:)`
then asserts *"text container must already have a layout manager."* `RichText` keeps the whole stack
(`TextKitStack`) in the SwiftUI `Coordinator`, so it lives as long as the view.

## Layout

- `Sources/RichText/Model/` - `RichTextDocument` (blocks + inline runs).
- `Sources/RichText/Markdown/` - the from-scratch Markdown parser (one input builder).
- `Sources/RichText/Rendering/` - attributes/theme, the attributed-string builder, the custom layout
  manager, and the SwiftUI `RichText`.
- `Sources/RichText/Serialization/` - RTF / HTML / Markdown writers + the pasteboard helper.
- `Tests/RichTextTests/` - parser + serializer tests.
- `Demo/` - a multiplatform demo app (xcodegen).
