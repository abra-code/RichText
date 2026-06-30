# RichTextView

A dependency-free, cross-platform (iOS / iPadOS / macOS / visionOS) component that renders a whole rich
document - headings, paragraphs, code blocks, block quotes, lists, GFM tables, inline styling, links -
into **one native text view**, so the entire document is **selectable and copyable as a single unit**.
Copy is **table-aware** (RTF / HTML / Markdown) so content round-trips into TextEdit / Notes / Word even
though iOS TextKit has no native table model.

Investigation and full plan: `Private/ios-richtext-view-design.md`.

## Usage

```swift
import RichTextView

// From Markdown:
RichTextView(markdown: "# Hello\n\nA **bold** word and a `code` span.")

// From the document model (build it however you like):
let doc = RichTextDocument(blocks: [.heading(level: 1, [.text("Hi")])])
RichTextView(doc)

// Copy the document as rich text (RTF table + HTML + Markdown) to the pasteboard:
RichTextPasteboard.write(doc)
```

`RichTextView` is read-only-but-selectable and self-sizes to its content for the proposed width, so it
drops into a `ScrollView` / `VStack` / a chat transcript directly. See `Demo/` for a runnable app.

## How it works

- **One model, one attributed string, one text view.** `RichTextDocument` (blocks + inline runs) is
  rendered by `RichTextAttributedString` into a single `NSAttributedString`, shown in an `NSTextView`
  (macOS) / `UITextView` (iOS) backed by an explicit TextKit 1 stack.
- **Draw-only decorations.** The code-block rounded rectangle, block-quote bar, thematic-break hairline,
  and the iOS table grid are PAINTED by a custom `NSLayoutManager` (`RichTextLayoutManager`) keyed off
  semantic marker attributes. They add no block structure to the text, so selection / copy stay clean and
  the same string works on both platforms.
- **Serialization is decoupled from rendering.** `RichTextRTFSerializer` writes real RTF tables
  (`\trowd` / `\cellx` / `\cell` / `\row`), `RichTextHTMLSerializer` writes `<table>`, and
  `RichTextMarkdownSerializer` writes Markdown - so copy carries a real table even on iOS, where TextKit
  cannot render one. `RichTextPasteboard` puts all representations on the pasteboard at once.

## Implementation status (phases P0-P4 of the design plan)

- **P0/P1 - decorations: DONE.** Code-block rounded background, block-quote bar, thematic-break hairline,
  inline-code background, headings, lists (hanging indents, nesting), links - cross-platform.
- **P2 - T1 tables: DONE.** Tab-stop, measured content-sized columns, drawn grid + header tint, single-line
  cells, selectable - cross-platform.
- **P3 - serializers: DONE.** RTF (table-aware) + HTML + Markdown writers + multi-representation pasteboard.
  Unit-tested (Markdown round-trip, HTML / RTF structure, escaping).
- **P4 - wrapping-cell tables: PARTIAL.** macOS renders wrapping cells via native `NSTextTable` (proven);
  iOS keeps T1 (single-line). Unifying iOS to wrapping cells is the remaining work - a TextKit 2 custom
  `NSTextLayoutFragment` (the design doc's strategic substrate).

## Key engineering decisions

- **TextKit 1, not TextKit 2 (yet).** The design doc recommends TextKit 2 strategically; this first
  implementation uses TextKit 1 with a custom `NSLayoutManager`, because that `drawBackground` pattern was
  already verified on macOS (it ports to iOS with high confidence) and it unifies both platforms on one
  path now. TextKit 2 custom layout fragments are the recommended migration (and the path to unified
  wrapping-cell tables) - tracked as the remaining P4 work.
- **Decouple copy from render.** Tables render per platform (NSTextTable on macOS, drawn grid on iOS) but
  copy ALWAYS goes through the serializer, so a copied table pastes as a real table everywhere.
- **No third-party dependencies.** The Markdown parser and all serializers are written from scratch.

## Verification

- `swift test` - 10 tests (parser + serializers), all pass.
- Library builds for macOS and iOS; the `Demo/` app builds for both.
- `Demo/` runs on the iOS simulator: launches cleanly and renders headings, inline styles, nested /
  ordered lists, the quote gutter bar, the rounded code card, the table (header tint + drawn grid), and
  the thematic-break hairline. Still worth a manual pass: one-selection sweep across the whole document
  and copy -> paste a real table into TextEdit / Notes.

### Note: the TextKit 1 stack must outlive the function that builds it

A TextKit 1 graph is rooted at the `NSTextStorage` (storage -> strong -> layout manager -> strong ->
container); the back-pointers `container.layoutManager` and `layoutManager.textStorage` are weak. The
text view holds only the container, so if nothing else retains the storage and layout manager they are
deallocated immediately, leaving `container.layoutManager == nil`. `UITextView(frame:textContainer:)`
then asserts *"text container must already have a layout manager."* `RichTextView` keeps the whole stack
(`TextKitStack`) in the SwiftUI `Coordinator`, so it lives as long as the view.

## Layout

- `Sources/RichTextView/Model/` - `RichTextDocument` (blocks + inline runs).
- `Sources/RichTextView/Markdown/` - the from-scratch Markdown parser (one input builder).
- `Sources/RichTextView/Rendering/` - attributes/theme, the attributed-string builder, the custom layout
  manager, and the SwiftUI `RichTextView`.
- `Sources/RichTextView/Serialization/` - RTF / HTML / Markdown writers + the pasteboard helper.
- `Tests/RichTextViewTests/` - parser + serializer tests.
- `Demo/` - a multiplatform demo app (xcodegen).
