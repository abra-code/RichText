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

/// How a RichText view resolves its width against the width SwiftUI proposes.
/// - `fill` (default): expands to the full proposed width, left-aligned - block / document layout. A
///   consumer that wants a full-width column relies on this (e.g. a transcript row with a tinted background).
/// - `hug`: sizes to the content's natural width, wrapping only when it would exceed the proposal. This is
///   the messaging-bubble idiom - a short message hugs, a long one wraps at the proposed cap. Pair it with a
///   `.frame(maxWidth:)` to bound how wide the bubble may grow.
public enum RichTextWidthBehavior: Sendable, Hashable {
    case fill
    case hug
}

public struct RichText: View {
    private let attributed: NSAttributedString
    private let engine: RichTextEngine
    private let metrics: RichTextDecorationMetrics
    private var widthBehavior: RichTextWidthBehavior = .fill
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

    /// Returns a copy that resolves its width with `behavior`. Defaults to `.fill`; pass `.hug` for a
    /// content-hugging bubble (see `RichTextWidthBehavior`).
    public func widthBehavior(_ behavior: RichTextWidthBehavior) -> RichText {
        var copy = self
        copy.widthBehavior = behavior
        return copy
    }

    public var body: some View {
        content
            // `.fill` expands to the proposed width (the original, default behavior); `.hug` leaves the view
            // at its content size (the representable's sizeThatFits already hugs). alignment matters only
            // when filling.
            .frame(maxWidth: widthBehavior == .fill ? .infinity : nil, alignment: .leading)
            // Render the whole document as ONE static-text element reading `accessibilityText`, ignoring the
            // text view's own accessibility (which would skip image alt text and run table columns together).
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var content: some View {
        switch engine {
        case .textKit1:
            RichTextRepresentableTK1(attributed: attributed, widthBehavior: widthBehavior)
        case .textKit2:
            RichTextRepresentableTK2(attributed: attributed, metrics: metrics, widthBehavior: widthBehavior)
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
func richTextResolvedLayout(proposalWidth: CGFloat?, storage: NSTextStorage?,
                            behavior: RichTextWidthBehavior = .fill) -> (width: CGFloat, naturalSize: CGSize?) {
    if let proposed = proposalWidth, proposed != .infinity {
        let cap = max(0, proposed)
        // Hug: size to the content, but never wider than the proposal. size() measures the natural unwrapped
        // width without a container (as in the ideal branch below). If it fits within the cap, hug to it and
        // return the natural size so the caller skips a second layout; if it exceeds the cap, wrap to the cap
        // and let the caller measure the wrapped height. `.fill` keeps the original policy: use the full cap.
        // Note: unlike `.fill`, this runs size() on every finite-width probe (SwiftUI probes several per pass);
        // it is aimed at short bubbles, so the extra measurement is cheap - keep that in mind for huge docs.
        if behavior == .hug {
            let ideal = storage?.size() ?? .zero
            let naturalWidth = ceil(ideal.width)
            if naturalWidth <= cap {
                return (naturalWidth, CGSize(width: naturalWidth, height: ceil(ideal.height)))
            }
            return (cap, nil)
        }
        return (cap, nil)
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
                                 liveWidth: CGFloat, behavior: RichTextWidthBehavior = .fill) -> CGSize {
    let (width, naturalSize) = richTextResolvedLayout(proposalWidth: proposalWidth, storage: storage, behavior: behavior)
    if let naturalSize {
        // Keep the container at a drawable, non-zero width for the eventual lazy draw - the on-screen width
        // if the view already has a frame, else the natural width - mirroring the finite branch's restore.
        container.size = CGSize(width: liveWidth > 0 ? liveWidth : max(1, width), height: CGFloat.greatestFiniteMagnitude)
        return naturalSize
    }
    container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    // Force a COMPLETE layout of the whole document before reading usedRect - by character range, not
    // ensureLayout(for:), which can return early against stale fragment state while a container-resize
    // invalidation is still propagating (observed live: the same width measuring 48pt on one probe and
    // 276pt on the next during a window resize; SwiftUI then paired the garbage height with the final
    // width and the bubble rendered shifted). Measurement must be deterministic for a given (text, width).
    layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: storage?.length ?? 0))
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
final class RichTextTopAlignedTextView: NSTextView, RichTextDiagnosableTextView, RichTextHostSnapping {
    let diag = RichTextViewDiagnostics()
    var snapsToHostBounds = false

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

    // Geometry diagnostics (see RichTextDiagnostics.swift): record who mutates the view's geometry,
    // and cross-check the whole chain just before each draw.
    override func setFrameSize(_ newSize: NSSize) {
        diag.noteFrameSize(self, from: frame.size, to: newSize)
        super.setFrameSize(newSize)
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        diag.noteFrameOrigin(self, from: frame.origin, to: newOrigin)
        super.setFrameOrigin(newOrigin)
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        diag.noteBoundsOrigin(self, from: bounds.origin, to: newOrigin)
        super.setBoundsOrigin(newOrigin)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        diag.note(self, "windowChange", window == nil ? "nil" : "attached")
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        snapToHostBoundsIfNeeded()
        diag.checkAndReport(self)
    }
}

private struct RichTextRepresentableTK1:NSViewRepresentable {
    let attributed: NSAttributedString
    let widthBehavior: RichTextWidthBehavior

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
        textView.snapsToHostBounds = true   // SwiftUI's adaptor sizes the platform view to fill its host
        RichTextDiagnostics.register(textView)
        textView.diag.note(textView, "make", "len=\(attributed.length)")
        startImageLoading(textView, stack)
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        let stack = context.coordinator
        if !stack.storage.isEqual(to: attributed) {
            (textView as? RichTextDiagnosableTextView)?.diag
                .note(textView, "contentChange", "len=\(stack.storage.length) -> \(attributed.length)")
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
        let size = richTextFittingSize(storage: context.coordinator.storage, container: container,
                                       layoutManager: layoutManager, proposalWidth: proposal.width,
                                       liveWidth: nsView.bounds.width, behavior: widthBehavior)
        (nsView as? RichTextDiagnosableTextView)?.diag.noteFit(nsView, proposalWidth: proposal.width, result: size)
        return size
    }
}

#elseif canImport(UIKit)

private struct RichTextRepresentableTK1:UIViewRepresentable {
    let attributed: NSAttributedString
    let widthBehavior: RichTextWidthBehavior

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
                                   liveWidth: uiView.bounds.width, behavior: widthBehavior)
    }
}

#endif
