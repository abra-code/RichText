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
    let provider: RichTextFragmentProvider   // the iOS path uses this directly as the layout-manager delegate
    var owner: AnyObject?                     // the macOS path retains the shared factory's delegate here

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

    // Builds the text view through the shared AppKit factory (RichTextAppKit) so the SwiftUI host and a
    // plain AppKit host exercise identical setup. The factory's text view is a SelectableTextView, which
    // clears the SwiftUI-installed gesture delay so click-drag selection / link clicks reach TextKit 2.
    func makeNSView(context: Context) -> NSTextView {
        let (textView, owner) = RichTextAppKit.makeTextKit2View(attributed: attributed, metrics: metrics)
        context.coordinator.owner = owner
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        if RichTextAppKit.currentContent(of: textView)?.isEqual(to: attributed) == false {
            RichTextAppKit.setContent(attributed, on: textView)
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
}

// When an NSView is embedded in SwiftUI via NSViewRepresentable, SwiftUI installs its own pan / click
// gesture recognizers on it with delaysPrimaryMouseButtonEvents = true. The pan recognizer buffers
// mouse-down / drag while it decides whether it owns the gesture, so primary mouse events reach the text
// view late and batched. A TextKit 2 NSTextView (which selects via normal event delivery) then never gets
// a real-time drag stream and click-drag selection silently fails - even though the caret cursor still
// shows on hover. Clearing the delay on each recognizer as it is attached restores selection. (TextKit 1
// is unaffected: its mouseDown enters a modal event-tracking loop that pulls events directly.)
final class SelectableTextView: NSTextView {
    override func addGestureRecognizer(_ gestureRecognizer: NSGestureRecognizer) {
        gestureRecognizer.delaysPrimaryMouseButtonEvents = false
        super.addGestureRecognizer(gestureRecognizer)
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
