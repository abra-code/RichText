// Sources/RichText/Search/RichTextSearchOptions.swift
//
// The platform-independent parts of the find engine: the options a query is matched with, and the plain-text
// linearization for indexing. The engines (RichTextSearch) are per platform: NSString and
// NSRegularExpression on Apple platforms, GLib on Linux; both take these options.

/// How a query is matched. All default to the forgiving setting (case- and diacritic-insensitive,
/// substring), which is what a find bar wants; an indexer can tighten them.
public struct RichTextSearchOptions: Equatable, Sendable {
    public var caseSensitive: Bool
    public var diacriticSensitive: Bool
    /// Match only where the query is bounded by non-word characters (or the text's ends). Word characters
    /// are letters, digits and the underscore. Applies to a regular expression's matches too.
    public var wholeWord: Bool
    /// Read the query as a regular expression instead of literal text: ICU syntax (NSRegularExpression) on
    /// Apple platforms, PCRE2 (GLib's GRegex) on Linux, which agree on everything but a few rare constructs.
    /// `^` and `$` match at line boundaries and `.` stops at a newline, which is what a find
    /// bar over a document wants. The other options keep their meaning: case folding becomes the engine's
    /// case-insensitive mode, diacritic folding strips marks from both the text and the pattern before
    /// matching (ranges are still reported in the original text; a combining mark in the pattern is dropped
    /// too, which can change what the pattern means or whether it compiles), and whole-word bounds each
    /// match. A match of zero length is skipped, so `a*` lights up the runs of "a" and not every position.
    /// A pattern that does not compile matches nothing; `RichTextSearch.isValidQuery` tells a bar to say so.
    public var regularExpression: Bool
    /// Stop after this many matches (nil: unbounded). A one-letter query over a long document yields
    /// thousands of hits, each of which a view then paints; a find bar that shows "1 of 5000+" can cap it.
    public var limit: Int?
    /// How many characters of context `RichTextMatch.snippet` keeps on either side of the match.
    public var snippetContext: Int

    public init(caseSensitive: Bool = false, diacriticSensitive: Bool = false, wholeWord: Bool = false,
                regularExpression: Bool = false, limit: Int? = nil, snippetContext: Int = 40) {
        self.caseSensitive = caseSensitive
        self.diacriticSensitive = diacriticSensitive
        self.wholeWord = wholeWord
        self.regularExpression = regularExpression
        self.limit = limit
        self.snippetContext = snippetContext
    }

    public static let `default` = RichTextSearchOptions()
}

/// The document as the plain text a reader sees, for indexing and for searching many documents without
/// rendering any of them: blocks one per line, images as their alt text, table rows as comma-separated
/// cells, code verbatim, no Markdown syntax. This is the same linearization VoiceOver reads, kept in one
/// place so what a screen reader speaks, what an index stores and what a find bar matches never drift.
public enum RichTextPlainText {
    /// Ranges found in THIS text are not view ranges: it is the indexing form, not the rendered string.
    /// Search the rendered form (`RichTextSearch.matches(in: document, ...)`) when a range must be painted.
    public static func text(for document: RichTextDocument) -> String {
        RichTextAccessibility.label(for: document)
    }
}
