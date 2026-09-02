// Sources/RichText/Find/RichTextFindController.swift
//
// Layer 3 of the find stack (see RichTextSearch.swift): the state behind a find bar over ONE document. It
// owns the query and options, runs the engine over the rendered text it is bound to, and tracks which match
// the user is on. It knows nothing about views: RichTextFindBar edits it, `RichText.find(_:)` paints its
// `highlights`, and a host with its own search field can drive `query` directly and never show the bar.
//
// A transcript of many documents does not use this - each message is its own RichText, and the transcript
// keeps one cross-message cursor of its own, handing each message just its ranges via `findHighlights`.
// ObservableObject (not @Observable): RichText's floor is macOS 13 / iOS 16.
//
// It keeps ranges, not RichTextMatch values: a bar shows "3 of 12" and paints, and never displays a
// snippet, so building one per hit on every keystroke would be waste. A result list wants
// `RichTextSearch.matches` instead.

import Foundation
import Combine

@MainActor
public final class RichTextFindController: ObservableObject {

    /// The text to find. Setting it re-runs the search; "" clears matches (the engine matches nothing
    /// for an empty query, so the document never lights up wholesale).
    @Published public var query: String = "" {
        didSet {
            if query != oldValue {
                recompute()
            }
        }
    }

    @Published public var options: RichTextSearchOptions = .default {
        didSet {
            if options != oldValue {
                recompute()
            }
        }
    }

    /// Whether the bar is shown. The controller only stores this; `richTextFindBar` reads it.
    @Published public var isPresented = false

    /// Bumped by `present(focus: true)` every time, so a repeat Cmd-F while the bar is already open
    /// still puts focus back in the field (a plain Bool would not change, and nothing would be
    /// published). The bar records the request it honored in `focusHonored`.
    @Published public private(set) var focusRequests = 0
    @Published public private(set) var focusHonored = 0

    /// Colors for the painted ranges.
    @Published public var style: RichTextHighlightStyle = .default

    @Published public private(set) var ranges: [NSRange] = []

    /// Index into `ranges` of the match the user is on; nil when there are none.
    @Published public private(set) var currentIndex: Int?

    /// The rendered text being searched (bound by `RichText.find(_:)`, or by hand for a headless host).
    public private(set) var text: String = ""

    public init() {}

    // MARK: - Binding to a document

    /// Search this rendered text from now on. The current match is kept when its range survives (the same
    /// text was re-bound), else the cursor goes back to the first match.
    public func bind(text: String) {
        guard text != self.text else {
            return
        }
        self.text = text
        recompute()
    }

    public func bind(attributed: NSAttributedString) {
        bind(text: attributed.string)
    }

    /// Bind to a document rendered with the same theme / engine as the view showing it, so the ranges the
    /// controller finds are the ranges the view paints.
    public func bind(document: RichTextDocument, theme: RichTextTheme = .default, engine: RichTextEngine = .textKit1) {
        bind(attributed: RichTextAttributedString.make(document, theme: theme, engine: engine))
    }

    // MARK: - Navigation

    public func next() {
        step(by: 1)
    }

    public func previous() {
        step(by: -1)
    }

    /// Jump to a specific match (a result-list tap).
    public func select(_ index: Int) {
        guard ranges.indices.contains(index) else {
            return
        }
        currentIndex = index
    }

    /// Hide the bar and clear the query, so nothing stays painted.
    public func dismiss() {
        isPresented = false
        query = ""
    }

    /// Show the bar. With `focus` (the reader's Cmd-F) its field takes focus, again if the bar is
    /// already open; without it (a host driving `query` from its own search field) the bar appears and
    /// focus stays where the reader is typing.
    public func present(focus: Bool = true) {
        isPresented = true
        if focus {
            focusRequests += 1
        }
    }

    /// The bar took the focus `focusRequests` asked for.
    public func markFocusHonored() {
        focusHonored = focusRequests
    }

    // MARK: - Derived

    /// What `RichText.findHighlights` should paint: nil when there is nothing to paint.
    public var highlights: RichTextHighlights? {
        guard !ranges.isEmpty else {
            return nil
        }
        return RichTextHighlights(ranges: ranges, current: currentIndex, style: style)
    }

    /// "3 of 12", "No matches", or "" for an empty query. With `options.limit` reached, "3 of 500+".
    public var summary: String {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ""
        }
        guard let currentIndex, !ranges.isEmpty else {
            return "No matches"
        }
        let capped = options.limit.map { ranges.count >= $0 } ?? false
        return "\(currentIndex + 1) of \(ranges.count)\(capped ? "+" : "")"
    }

    // MARK: - Private

    private func step(by delta: Int) {
        guard !ranges.isEmpty else {
            return
        }
        let count = ranges.count
        let base = currentIndex ?? (delta > 0 ? -1 : 0)
        currentIndex = ((base + delta) % count + count) % count
    }

    private func recompute() {
        let previousRange = currentIndex.flatMap { ranges.indices.contains($0) ? ranges[$0] : nil }
        ranges = RichTextSearch.ranges(in: text, query: query, options: options)
        if ranges.isEmpty {
            currentIndex = nil
        } else if let previousRange, let kept = ranges.firstIndex(of: previousRange) {
            currentIndex = kept
        } else {
            currentIndex = 0
        }
    }
}
