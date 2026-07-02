// Sources/RichText/Rendering/RichTextAppKit.swift
//
// The AppKit (no SwiftUI) construction of the TextKit 2 rich-text view, factored out so a plain AppKit
// host and the SwiftUI representable build the EXACT same text view. This lets the two be compared to
// isolate which layer (AppKit text-view setup vs the SwiftUI embedding) affects selection / link clicks.

#if canImport(AppKit)
import AppKit

@MainActor
public enum RichTextAppKit {
    /// Builds the TextKit 2 NSTextView for `document` plus the `owner` object that must be retained for the
    /// view's lifetime (the layout manager keeps only a weak reference to its delegate). Host it directly -
    /// e.g. as an NSScrollView's documentView - to exercise selection / links without SwiftUI in the way.
    public static func makeTextKit2View(_ document: RichTextDocument,
                                        theme: RichTextTheme = .default) -> (textView: NSTextView, owner: AnyObject) {
        let attributed = RichTextAttributedString.make(document, theme: theme, engine: .textKit2)
        let metrics = RichTextDecorationMetrics(codeCornerRadius: theme.codeCornerRadius)
        return makeTextKit2View(attributed: attributed, metrics: metrics)
    }

    /// Same, from a pre-built attributed string (used by the SwiftUI representable, which renders once at
    /// init). Returns the configured text view and the delegate to retain.
    static func makeTextKit2View(attributed: NSAttributedString,
                                 metrics: RichTextDecorationMetrics) -> (textView: NSTextView, owner: AnyObject) {
        let textView = SelectableTextView(usingTextLayoutManager: true)
        let provider = RichTextFragmentProvider(metrics: metrics)
        textView.textLayoutManager?.delegate = provider
        applyStandardConfig(textView)
        setContent(attributed, on: textView)
        return (textView, provider)
    }

    /// Configure a CALLER-PROVIDED TextKit 2 text view (e.g. a diagnostics subclass). When `decorations` is
    /// false the custom layout-fragment delegate is NOT attached, so the view is a plain TextKit 2 text
    /// view - useful for isolating whether the custom fragment affects selection / hit-testing. Returns the
    /// delegate to retain (nil when decorations are off).
    public static func configureTextKit2(_ textView: NSTextView, document: RichTextDocument,
                                         theme: RichTextTheme = .default, decorations: Bool = true) -> AnyObject? {
        var owner: AnyObject?
        if decorations {
            let provider = RichTextFragmentProvider(metrics: RichTextDecorationMetrics(codeCornerRadius: theme.codeCornerRadius))
            textView.textLayoutManager?.delegate = provider
            owner = provider
        }
        applyStandardConfig(textView)
        setContent(RichTextAttributedString.make(document, theme: theme, engine: .textKit2), on: textView)
        return owner
    }

    private static func applyStandardConfig(_ textView: NSTextView) {
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
    }

    // Set content on the text view's OWN NSTextStorage, NOT via NSTextContentStorage.attributedString.
    // This is the macOS TextKit 2 selection fix: injecting content through the content storage's
    // attributedString renders and hit-tests correctly but leaves NSTextView unable to establish a
    // selection (clicks / drag / Cmd+A produce nothing, link clicks do not fire) - the text view's
    // selection machinery is bound to its textStorage, which that path never populates. Setting via
    // textStorage restores selection and does NOT downgrade to TextKit 1 (textLayoutManager stays non-nil;
    // verified in the AppKit diagnostic host).
    static func setContent(_ attributed: NSAttributedString, on textView: NSTextView) {
        textView.textStorage?.setAttributedString(attributed)
        // TextKit 2 cannot lay out NSTextTable (RTF / HTML decoded tables): NSTextView downgrades ITSELF
        // to TextKit 1 the moment layout meets a text block. Left to happen mid-layout, the first SwiftUI
        // sizeThatFits still measures with TK2 (table cells stacked as plain paragraphs - the wrong
        // height), and the stale height lingers as blank space. Trigger the inevitable downgrade eagerly
        // instead, so every measure and draw uses one engine. (.layoutManager on a TK2 view forces it.)
        if textView.textLayoutManager != nil, containsTextBlocks(attributed) {
            _ = textView.layoutManager
        }
    }

    private static func containsTextBlocks(_ attributed: NSAttributedString) -> Bool {
        var found = false
        attributed.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: attributed.length)) { value, _, stop in
            if let style = value as? NSParagraphStyle, !style.textBlocks.isEmpty {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    static func currentContent(of textView: NSTextView) -> NSAttributedString? {
        return textView.textStorage
    }
}
#endif
