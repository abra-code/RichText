// Sources/RichTextView/Rendering/RichTextUIKit.swift
//
// The UIKit (no SwiftUI) construction of the TextKit 2 rich-text view - the parity counterpart to
// RichTextAppKit. A plain UIKit host and the SwiftUI representable build the EXACT same UITextView through
// this factory, so they cannot drift and the view can be embedded in a UIKit app directly.
//
// Note the macOS-vs-iOS difference in how content is injected (the macOS TextKit 2 selection bug): on iOS,
// UITextView.attributedText IS the correct content setter and binds selection properly, so we use it.
// (On macOS we had to use textStorage instead of NSTextContentStorage.attributedString - see RichTextAppKit.)

#if canImport(UIKit)
import UIKit

@MainActor
public enum RichTextUIKit {
    /// Builds the TextKit 2 UITextView for `document` plus the `owner` object that must be retained for the
    /// view's lifetime (the layout manager keeps only a weak reference to its delegate). Host it directly -
    /// e.g. add it to a view controller's view - to get selection, links, and the decorations.
    public static func makeTextKit2View(_ document: RichTextDocument,
                                        theme: RichTextTheme = .default) -> (textView: UITextView, owner: AnyObject) {
        let attributed = RichTextAttributedString.make(document, theme: theme, engine: .textKit2)
        let metrics = RichTextDecorationMetrics(codeCornerRadius: theme.codeCornerRadius)
        return makeTextKit2View(attributed: attributed, metrics: metrics)
    }

    /// Same, from a pre-built attributed string (used by the SwiftUI representable, which renders once at
    /// init). Returns the configured text view and the delegate to retain.
    static func makeTextKit2View(attributed: NSAttributedString,
                                 metrics: RichTextDecorationMetrics) -> (textView: UITextView, owner: AnyObject) {
        let textView = UITextView(usingTextLayoutManager: true)
        let provider = RichTextFragmentProvider(metrics: metrics)
        textView.textLayoutManager?.delegate = provider
        applyStandardConfig(textView)
        setContent(attributed, on: textView)
        return (textView, provider)
    }

    /// Configure a CALLER-PROVIDED TextKit 2 text view. When `decorations` is false the custom layout-
    /// fragment delegate is NOT attached (plain TextKit 2) - the parity of RichTextAppKit.configureTextKit2.
    /// Returns the delegate to retain (nil when decorations are off).
    public static func configureTextKit2(_ textView: UITextView, document: RichTextDocument,
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

    private static func applyStandardConfig(_ textView: UITextView) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false   // self-sizing default; a scrolling host can set it true
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.linkTextAttributes = [.foregroundColor: UIColor.link]
    }

    /// Replace the text view's content. On iOS, attributedText is the proper UITextView setter and binds
    /// selection correctly (unlike the macOS content-storage path), and it does not downgrade TextKit 2.
    static func setContent(_ attributed: NSAttributedString, on textView: UITextView) {
        textView.attributedText = attributed
    }

    static func currentContent(of textView: UITextView) -> NSAttributedString? {
        return textView.attributedText
    }
}
#endif
