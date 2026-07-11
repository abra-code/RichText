// Sources/RichText/Rendering/RichTextTK2.swift
//
// The TextKit 2 backend for RichText: hosts the document in a TK2-backed text view whose layout
// manager vends our custom RichTextLayoutFragment (RichTextLayoutFragment.swift) to paint decorations.
// It is read-only-but-selectable, non-scrolling, transparent, and self-sizes by measuring the laid-out
// fragments. The TextKit 1 backend (RichTextRepresentableTK1, in RichText.swift) is unchanged; the
// two are selected by RichTextEngine so they can be compared.

import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// Retains the one TK2 piece that must outlive a render pass: the fragment provider, which the layout
// manager keeps only a WEAK reference to. Both platforms build the text view through the shared factory
// (RichTextAppKit / RichTextUIKit), which returns that provider as `owner` for the coordinator to hold.
final class TextKit2Coordinator {
    var owner: AnyObject?
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
    let widthBehavior: RichTextWidthBehavior

    func makeCoordinator() -> TextKit2Coordinator {
        TextKit2Coordinator()
    }

    // Builds the text view through the shared AppKit factory (RichTextAppKit) so the SwiftUI host and a
    // plain AppKit host exercise identical setup. The factory's text view is a SelectableTextView, which
    // clears the SwiftUI-installed gesture delay so click-drag selection / link clicks reach TextKit 2.
    func makeNSView(context: Context) -> NSTextView {
        let (textView, owner) = RichTextAppKit.makeTextKit2View(attributed: attributed, metrics: metrics)
        context.coordinator.owner = owner
        startImageLoading(textView)
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        if RichTextAppKit.currentContent(of: textView)?.isEqual(to: attributed) == false {
            RichTextAppKit.setContent(attributed, on: textView)
            textView.invalidateIntrinsicContentSize()
            startImageLoading(textView)
        }
    }

    // Fetch image attachments; when each arrives, re-apply cached images to the live content and re-lay-out.
    private func startImageLoading(_ textView: NSTextView) {
        guard let content = RichTextAppKit.currentContent(of: textView) else {
            return
        }
        RichTextImageLoading.startLoading(in: content) { [weak textView] in
            guard let textView, let content = RichTextAppKit.currentContent(of: textView),
                  let layoutManager = textView.textLayoutManager else {
                return
            }
            RichTextImageLoading.applyCached(in: content)
            layoutManager.invalidateLayout(for: layoutManager.documentRange)
            textView.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        // Resolve the width like the TK1 twin (see richTextResolvedLayout): a finite proposal wraps to it, an
        // unspecified / infinite one sizes to the natural content width - never the live bounds width, which
        // is 0 on the first layout pass. TK2 lays decorations out through a custom fragment whose height can
        // differ from NSAttributedString.size() (code blocks, quotes), so only the WIDTH is borrowed; the
        // height is measured below via the TK2 fragments.
        let width = richTextResolvedLayout(proposalWidth: proposal.width, storage: nsView.textStorage,
                                           behavior: widthBehavior).width
        nsView.textContainer?.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        let height: CGFloat
        if let layoutManager = nsView.textLayoutManager {
            height = ceil(measuredHeight(layoutManager))
        } else if let layoutManager = nsView.layoutManager, let container = nsView.textContainer {
            // NSTextView silently downgrades itself to TextKit 1 for content TK2 cannot lay out (e.g.
            // NSTextTable decoded from RTF / HTML); textLayoutManager is nil from then on. Measure via the
            // TK1 stack instead of giving SwiftUI no answer. Only reached AFTER a downgrade - merely
            // touching .layoutManager on a live TK2 view would itself force one.
            layoutManager.ensureLayout(for: container)
            height = ceil(layoutManager.usedRect(for: container).height)
        } else {
            return nil
        }
        // Measuring mutates the LIVE container and SwiftUI probes several widths (including 0); the
        // container only re-tracks the view on an actual frame CHANGE. Restore the on-screen width so
        // drawing never uses probe geometry (a width-0 container draws nothing). See the TK1 twin.
        let liveWidth = nsView.bounds.width
        if liveWidth > 0, liveWidth != width {
            nsView.textContainer?.size = CGSize(width: liveWidth, height: CGFloat.greatestFiniteMagnitude)
        }
        return CGSize(width: width, height: height)
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

    // Keep glyphs pinned to the top of the view - the TextKit 2 twin of RichTextTopAlignedTextView. If the
    // layout leaves a gap above the first line/fragment, the text renders low inside the chat bubble; subtract
    // that offset so it always draws from the top (a no-op when there is no offset). The offset is the top of
    // the first TK2 layout fragment; if the view has downgraded itself to TextKit 1 (NSTextTable content), fall
    // back to the TK1 used rect, matching the sizeThatFits height path.
    private var isMeasuringOrigin = false
    override var textContainerOrigin: NSPoint {
        let base = NSPoint(x: textContainerInset.width, y: textContainerInset.height)
        // Guard against re-entrancy: forcing layout below can query this origin back.
        guard !isMeasuringOrigin else {
            return base
        }
        isMeasuringOrigin = true
        defer { isMeasuringOrigin = false }
        let top: CGFloat
        if let layoutManager = textLayoutManager {
            var firstMinY: CGFloat = 0
            layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location,
                                                       options: [.ensuresLayout]) { fragment in
                firstMinY = fragment.layoutFragmentFrame.minY
                return false   // first fragment only - it is the topmost
            }
            top = firstMinY
        } else if let layoutManager, let textContainer {
            top = layoutManager.usedRect(for: textContainer).minY
        } else {
            return base
        }
        return NSPoint(x: base.x, y: base.y - top)
    }
}

#elseif canImport(UIKit)

struct RichTextRepresentableTK2: UIViewRepresentable {
    let attributed: NSAttributedString
    let metrics: RichTextDecorationMetrics
    let widthBehavior: RichTextWidthBehavior

    func makeCoordinator() -> TextKit2Coordinator {
        TextKit2Coordinator()
    }

    // Builds the text view through the shared UIKit factory (RichTextUIKit) so the SwiftUI host and a plain
    // UIKit host exercise identical setup.
    func makeUIView(context: Context) -> UITextView {
        let (textView, owner) = RichTextUIKit.makeTextKit2View(attributed: attributed, metrics: metrics)
        context.coordinator.owner = owner
        startImageLoading(textView)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if RichTextUIKit.currentContent(of: textView)?.isEqual(to: attributed) == false {
            RichTextUIKit.setContent(attributed, on: textView)
            textView.invalidateIntrinsicContentSize()
            startImageLoading(textView)
        }
    }

    private func startImageLoading(_ textView: UITextView) {
        guard let content = RichTextUIKit.currentContent(of: textView) else {
            return
        }
        RichTextImageLoading.startLoading(in: content) { [weak textView] in
            guard let textView, let content = RichTextUIKit.currentContent(of: textView),
                  let layoutManager = textView.textLayoutManager else {
                return
            }
            RichTextImageLoading.applyCached(in: content)
            layoutManager.invalidateLayout(for: layoutManager.documentRange)
            textView.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        // See the AppKit twin: borrow only the WIDTH from the shared resolver (natural content width for an
        // unspecified / infinite proposal, never the live bounds width); TK2 measures its own height below.
        let width = richTextResolvedLayout(proposalWidth: proposal.width, storage: uiView.textStorage,
                                           behavior: widthBehavior).width
        uiView.textContainer.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        let height: CGFloat
        if let layoutManager = uiView.textLayoutManager {
            height = ceil(measuredHeight(layoutManager))
        } else {
            height = ceil(uiView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height)
        }
        // See the AppKit twin: restore the on-screen width so drawing never uses probe geometry.
        let liveWidth = uiView.bounds.width
        if liveWidth > 0, liveWidth != width {
            uiView.textContainer.size = CGSize(width: liveWidth, height: CGFloat.greatestFiniteMagnitude)
        }
        return CGSize(width: width, height: height)
    }
}

#endif
