// Sources/RichTextView/Rendering/RichTextView.swift
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

public struct RichTextView: View {
    private let attributed: NSAttributedString

    public init(_ document: RichTextDocument, theme: RichTextTheme = .default) {
        self.attributed = RichTextAttributedString.make(document, theme: theme)
    }

    public init(markdown: String, theme: RichTextTheme = .default) {
        self.init(RichTextDocument(markdown: markdown), theme: theme)
    }

    public init(attributed: NSAttributedString) {
        self.attributed = attributed
    }

    public var body: some View {
        RichTextRepresentable(attributed: attributed)
            .frame(maxWidth: .infinity, alignment: .leading)
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

private struct RichTextRepresentable: NSViewRepresentable {
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
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        let storage = context.coordinator.storage
        if !storage.isEqual(to: attributed) {
            storage.setAttributedString(attributed)
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

private struct RichTextRepresentable: UIViewRepresentable {
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
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let storage = context.coordinator.storage
        if !storage.isEqual(to: attributed) {
            storage.setAttributedString(attributed)
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
