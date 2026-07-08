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

// The width RichText lays out at for a SwiftUI size proposal, shared by BOTH TextKit backends so their width
// policy cannot drift. A FINITE proposal wraps to that width. An UNSPECIFIED (nil) or INFINITE proposal
// sizes to content, so `naturalSize` carries the natural, unwrapped extent from one NSAttributedString.size()
// (nil for a finite proposal, whose height the caller measures at `width`).
//
// This never falls back to the live container / bounds width. That is mutable probe state: SwiftUI drives
// sizeThatFits at several widths in one pass (the real width, then 0, then nil), and on the FIRST layout
// pass - before the view has a frame, so the restore in each caller is a no-op - the nil (ideal-size) probe
// would inherit a 0-width container and report a bogus one-line size. A LazyVStack sizes its rows lazily and
// caches that ideal, so a chat bubble materialized with the wrong height - text shifted down inside the
// bubble and clipped below it - until a fresh layout was forced (scrolling the row off screen and back). See
// RichTextChatSizingTests. size() also measures WITHOUT a container, so it avoids the used-width clamp a live
// widthTracksTextView container imposes at large widths.
func richTextResolvedLayout(proposalWidth: CGFloat?, storage: NSTextStorage?) -> (width: CGFloat, naturalSize: CGSize?) {
    if let proposed = proposalWidth, proposed != .infinity {
        return (max(0, proposed), nil)
    }
    let ideal = storage?.size() ?? .zero
    return (ceil(ideal.width), CGSize(width: ceil(ideal.width), height: ceil(ideal.height)))
}

// The TextKit 1 sizeThatFits body (both platform twins delegate here). Because TK1's decorations are
// draw-only (RichTextLayoutManager overrides drawing only, never glyph geometry), the unwrapped size() from
// richTextResolvedLayout is the exact ideal size, so the ideal case returns it directly - one measurement
// pass, no second layout. A finite proposal is measured by the layout manager at that width.
private func richTextFittingSize(storage: NSTextStorage?, container: NSTextContainer,
                                 layoutManager: NSLayoutManager, proposalWidth: CGFloat?,
                                 liveWidth: CGFloat) -> CGSize {
    let (width, naturalSize) = richTextResolvedLayout(proposalWidth: proposalWidth, storage: storage)
    if let naturalSize {
        // Keep the container at a drawable, non-zero width for the eventual lazy draw - the on-screen width
        // if the view already has a frame, else the natural width - mirroring the finite branch's restore.
        container.size = CGSize(width: liveWidth > 0 ? liveWidth : max(1, width), height: CGFloat.greatestFiniteMagnitude)
        return naturalSize
    }
    container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    layoutManager.ensureLayout(for: container)
    let height = ceil(layoutManager.usedRect(for: container).height)
    // Measuring mutates the LIVE container, and SwiftUI probes several widths (including 0) in one pass.
    // widthTracksTextView only re-tracks the container on an actual frame CHANGE, so if the final probe is
    // not the final frame width and the frame is already correct, the view would draw with the probe's
    // geometry - a width-0 container draws no glyphs at all. Restore the on-screen width after measuring so
    // drawing never uses probe state.
    if liveWidth > 0, liveWidth != width {
        container.size = CGSize(width: liveWidth, height: CGFloat.greatestFiniteMagnitude)
    }
    return CGSize(width: width, height: height)
}

#if canImport(AppKit)

// Read-only text view that keeps its glyphs pinned to the top of its bounds. TextKit 1 can lay the first
// line fragment out below y = 0 (usedRect.minY > 0) - observed intermittently when a persisted transcript
// materializes its bubbles in a LazyVStack and the layout is measured against a transiently different frame,
// after which it sticks until the row is re-created. NSTextView's default textContainerOrigin does not undo
// that offset, so the text renders low inside the bubble. Subtracting the offset draws the text from the top;
// when there is no offset (the normal case, minY == 0) this is a no-op.
final class RichTextTopAlignedTextView: NSTextView {
    private var isMeasuringOrigin = false
    override var textContainerOrigin: NSPoint {
        let base = NSPoint(x: textContainerInset.width, y: textContainerInset.height)
        // Guard against re-entrancy: querying usedRect forces layout, which can query this origin back.
        guard !isMeasuringOrigin, let layoutManager, let textContainer else {
            return base
        }
        isMeasuringOrigin = true
        defer { isMeasuringOrigin = false }
        return NSPoint(x: base.x, y: base.y - layoutManager.usedRect(for: textContainer).minY)
    }
}

private struct RichTextRepresentableTK1:NSViewRepresentable {
    let attributed: NSAttributedString

    func makeCoordinator() -> TextKitStack {
        TextKitStack()
    }

    func makeNSView(context: Context) -> NSTextView {
        let stack = context.coordinator
        stack.storage.setAttributedString(attributed)
        let textView = RichTextTopAlignedTextView(frame: .zero, textContainer: stack.container)
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
        return richTextFittingSize(storage: context.coordinator.storage, container: container,
                                   layoutManager: layoutManager, proposalWidth: proposal.width,
                                   liveWidth: nsView.bounds.width)
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
        return richTextFittingSize(storage: stack.storage, container: stack.container,
                                   layoutManager: stack.layoutManager, proposalWidth: proposal.width,
                                   liveWidth: uiView.bounds.width)
    }
}

#endif
