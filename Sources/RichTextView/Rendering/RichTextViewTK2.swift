// Sources/RichTextView/Rendering/RichTextViewTK2.swift
//
// The TextKit 2 backend for RichTextView: hosts the document in a TK2-backed text view whose layout
// manager vends our custom RichTextLayoutFragment (RichTextLayoutFragment.swift) to paint decorations.
// It is read-only-but-selectable, non-scrolling, transparent, and self-sizes by measuring the laid-out
// fragments. The TextKit 1 backend (RichTextRepresentableTK1, in RichTextView.swift) is unchanged; the
// two are selected by RichTextEngine so they can be compared.

import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// Retains the TK2 pieces that must outlive a render pass. The fragment provider is a WEAK delegate of the
// layout manager, so it has to be held here. Both platforms let the text view OWN its TextKit 2 stack
// (created via the usingTextLayoutManager: initializer) and only attach the provider - hand-building the
// stack and handing NSTextView a container is associated with broken / asserting selection on macOS.
final class TextKit2Coordinator {
    let provider: RichTextFragmentProvider

    init(metrics: RichTextDecorationMetrics) {
        provider = RichTextFragmentProvider(metrics: metrics)
    }
}

// Full content height under TextKit 2: force layout and take the bottom of the lowest fragment.
private func measuredHeight(_ layoutManager: NSTextLayoutManager) -> CGFloat {
    var maxY: CGFloat = 0
    layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location,
                                               options: [.ensuresLayout]) { fragment in
        maxY = max(maxY, fragment.layoutFragmentFrame.maxY)
        return true
    }
    return maxY
}

#if canImport(AppKit)

struct RichTextRepresentableTK2: NSViewRepresentable {
    let attributed: NSAttributedString
    let metrics: RichTextDecorationMetrics

    func makeCoordinator() -> TextKit2Coordinator {
        TextKit2Coordinator(metrics: metrics)
    }

    func makeNSView(context: Context) -> NSTextView {
        // usingTextLayoutManager: true gives a TextKit 2 text view that owns its stack and drives its own
        // selection / viewport. Attach the fragment provider before content so the custom fragments are
        // used the first time layout runs. Content is set on the content storage (a TextKit 2 accessor) to
        // avoid the TextKit 1 bridges (.textStorage / .layoutManager) that would downgrade the view.
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.textLayoutManager?.delegate = context.coordinator.provider
        setContent(attributed, on: textView)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        if contentStorage(of: textView)?.attributedString?.isEqual(to: attributed) == false {
            setContent(attributed, on: textView)
            textView.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        nsView.textContainer?.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        guard let layoutManager = nsView.textLayoutManager else {
            return nil
        }
        return CGSize(width: width, height: ceil(measuredHeight(layoutManager)))
    }

    private func contentStorage(of textView: NSTextView) -> NSTextContentStorage? {
        return textView.textLayoutManager?.textContentManager as? NSTextContentStorage
    }

    private func setContent(_ attributed: NSAttributedString, on textView: NSTextView) {
        contentStorage(of: textView)?.attributedString = attributed
    }
}

#elseif canImport(UIKit)

struct RichTextRepresentableTK2: UIViewRepresentable {
    let attributed: NSAttributedString
    let metrics: RichTextDecorationMetrics

    func makeCoordinator() -> TextKit2Coordinator {
        TextKit2Coordinator(metrics: metrics)
    }

    func makeUIView(context: Context) -> UITextView {
        // usingTextLayoutManager: true gives a TextKit 2 text view. Attach our fragment provider before
        // content so the custom fragments are used the first time layout runs. We deliberately avoid the
        // TextKit 1 bridges (.layoutManager / .textStorage), which would silently downgrade the view.
        let textView = UITextView(usingTextLayoutManager: true)
        textView.textLayoutManager?.delegate = context.coordinator.provider
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.linkTextAttributes = [.foregroundColor: UIColor.link]
        textView.attributedText = attributed
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.attributedText != attributed {
            textView.attributedText = attributed
            textView.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        uiView.textContainer.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        guard let layoutManager = uiView.textLayoutManager else {
            let fitted = uiView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
            return CGSize(width: width, height: ceil(fitted.height))
        }
        return CGSize(width: width, height: ceil(measuredHeight(layoutManager)))
    }
}

#endif
