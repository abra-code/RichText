// Sources/RichText/Rendering/RichText.swift
//
// The public SwiftUI view. Renders a whole document into ONE native text view (NSTextView on macOS,
// UITextView on iOS / visionOS), backed by an explicit TextKit 1 stack (NSTextStorage + the custom
// RichTextLayoutManager + NSTextContainer) so the layout manager can paint block decorations. The text
// view is read-only-but-selectable, non-scrolling, transparent, handles links, and self-sizes via
// `sizeThatFits` so it participates in a SwiftUI layout (e.g. a transcript's vertical stack).

import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Which TextKit substrate renders the view. The two paths are visually equivalent for everything except
/// tables; they exist side by side so they can be switched and compared (see the design doc).
/// - `textKit1`: a custom NSLayoutManager paints decorations; tables use native NSTextTable on macOS.
/// - `textKit2`: a custom NSTextLayoutFragment paints decorations; tables use one drawn-grid path on both
///   platforms (the substrate for the future wrapping-cell fragment, Strategy T2).
public enum RichTextEngine: Sendable, Hashable {
    case textKit1
    case textKit2
}

public struct RichText: View {
    private let attributed: NSAttributedString
    private let engine: RichTextEngine
    private let metrics: RichTextDecorationMetrics
    // The VoiceOver reading of the whole document, built from the model (see RichTextAccessibility): images
    // speak their alt text, tables read row by row - neither of which is recoverable from the glyph stream of
    // the single rendered text view.
    private let accessibilityText: String

    public init(_ document: RichTextDocument, theme: RichTextTheme = .default, engine: RichTextEngine = .textKit1) {
        self.engine = engine
        self.attributed = RichTextAttributedString.make(document, theme: theme, engine: engine)
        self.metrics = RichTextDecorationMetrics(codeCornerRadius: theme.codeCornerRadius)
        self.accessibilityText = RichTextAccessibility.label(for: document)
    }

    public init(markdown: String, theme: RichTextTheme = .default, engine: RichTextEngine = .textKit1) {
        self.init(RichTextDocument(markdown: markdown), theme: theme, engine: engine)
    }

    public init(attributed: NSAttributedString, engine: RichTextEngine = .textKit1) {
        self.engine = engine
        self.attributed = attributed
        self.metrics = RichTextDecorationMetrics()
        // No model to linearize here; fall back to the raw text with attachment placeholders (U+FFFC) stripped.
        self.accessibilityText = attributed.string
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            // Render the whole document as ONE static-text element reading `accessibilityText`, ignoring the
            // text view's own accessibility (which would skip image alt text and run table columns together).
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var content: some View {
        switch engine {
        case .textKit1:
            RichTextRepresentableTK1(attributed: attributed)
        case .textKit2:
            RichTextRepresentableTK2(attributed: attributed, metrics: metrics)
        }
    }
}

// Owns the explicit TextKit 1 stack used by both platforms. The text view holds only a strong reference
// to its NSTextContainer, but the ownership root of a TextKit 1 graph is the NSTextStorage
// (storage -> strong -> layoutManager -> strong -> container; the back-pointers container.layoutManager
// and layoutManager.textStorage are weak). If nothing retains the storage and layout manager they are
// deallocated the moment the stack is built, leaving the container with a nil layoutManager - which makes
// UITextView(frame:textContainer:) assert "text container must already have a layout manager". So the
// SwiftUI Coordinator keeps the whole stack alive for the lifetime of the view.
private final class TextKitStack {
    let storage: NSTextStorage
    let layoutManager: RichTextLayoutManager
    let container: NSTextContainer

    init() {
        storage = NSTextStorage()
        layoutManager = RichTextLayoutManager()
        storage.addLayoutManager(layoutManager)
        container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
    }
}

#if canImport(AppKit)

private struct RichTextRepresentableTK1:NSViewRepresentable {
    let attributed: NSAttributedString

    func makeCoordinator() -> TextKitStack {
        TextKitStack()
    }

    func makeNSView(context: Context) -> NSTextView {
        let stack = context.coordinator
        stack.storage.setAttributedString(attributed)
        let textView = NSTextView(frame: .zero, textContainer: stack.container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        startImageLoading(textView, stack)
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        let stack = context.coordinator
        if !stack.storage.isEqual(to: attributed) {
            stack.storage.setAttributedString(attributed)
            textView.invalidateIntrinsicContentSize()
            startImageLoading(textView, stack)
        }
    }

    // Fetch image attachments; when each arrives, re-apply cached images to the LIVE storage and re-lay-out
    // (the attachment's placeholder size grows to the image size). Runs against stack.storage, not the
    // captured `attributed`, so it is correct even if SwiftUI rebuilt the view with a new attributed string.
    private func startImageLoading(_ textView: NSTextView, _ stack: TextKitStack) {
        RichTextImageLoading.startLoading(in: stack.storage) { [weak textView, weak stack] in
            guard let textView, let stack else {
                return
            }
            RichTextImageLoading.applyCached(in: stack.storage)
            stack.layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: stack.storage.length),
                                                 actualCharacterRange: nil)
            textView.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let container = nsView.textContainer, let layoutManager = nsView.layoutManager else {
            return nil
        }
        let width = proposal.width ?? container.size.width
        container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layoutManager.usedRect(for: container).height))
    }
}

#elseif canImport(UIKit)

private struct RichTextRepresentableTK1:UIViewRepresentable {
    let attributed: NSAttributedString

    func makeCoordinator() -> TextKitStack {
        TextKitStack()
    }

    func makeUIView(context: Context) -> UITextView {
        let stack = context.coordinator
        stack.storage.setAttributedString(attributed)
        let textView = UITextView(frame: .zero, textContainer: stack.container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.adjustsFontForContentSizeCategory = true
        textView.linkTextAttributes = [.foregroundColor: UIColor.link]
        startImageLoading(textView, stack)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let stack = context.coordinator
        if !stack.storage.isEqual(to: attributed) {
            stack.storage.setAttributedString(attributed)
            textView.invalidateIntrinsicContentSize()
            startImageLoading(textView, stack)
        }
    }

    // See the AppKit twin: reload against the LIVE storage so it survives view/attributed rebuilds.
    private func startImageLoading(_ textView: UITextView, _ stack: TextKitStack) {
        RichTextImageLoading.startLoading(in: stack.storage) { [weak textView, weak stack] in
            guard let textView, let stack else {
                return
            }
            RichTextImageLoading.applyCached(in: stack.storage)
            stack.layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: stack.storage.length),
                                                 actualCharacterRange: nil)
            textView.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let stack = context.coordinator
        let width = proposal.width ?? uiView.bounds.width
        stack.container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        stack.layoutManager.ensureLayout(for: stack.container)
        return CGSize(width: width, height: ceil(stack.layoutManager.usedRect(for: stack.container).height))
    }
}

#endif
