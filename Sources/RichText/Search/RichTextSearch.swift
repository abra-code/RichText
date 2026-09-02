// Sources/RichText/Search/RichTextSearch.swift
//
// The find ENGINE: pure functions from text + query to match ranges, with no view, no state and no
// platform types beyond Foundation. It is the bottom of a three-layer stack:
//   1. this engine (RichTextSearch, RichTextPlainText) - usable headless, e.g. by an indexer or a host
//      that searches many documents it never renders;
//   2. RichTextHighlights - a draw-only view modifier that paints ranges the engine found;
//   3. RichTextFindBar / RichTextFindController - the standalone find UI over one document.
// Each layer is usable without the one above it: a chat transcript search runs the engine over every
// message and feeds each message's ranges to layer 2, never touching layer 3.
//
// Matches are reported as NSRanges in the RENDERED string - the `.string` of the attributed string the
// view draws (image attachments are one U+FFFC each, table cells are tab-separated) - so a match is
// directly usable as a highlight range and as a selection range, and a headless search over a document
// finds exactly what the view would highlight. The rendered string is deterministic for (document, theme,
// engine); the two engines differ only in table layout, and searching a table cell gives the same text
// in both, so callers that only need ranges may use either.

import Foundation

/// How a query is matched. All default to the forgiving setting (case- and diacritic-insensitive,
/// substring), which is what a find bar wants; an indexer can tighten them.
public struct RichTextSearchOptions: Equatable, Sendable {
    public var caseSensitive: Bool
    public var diacriticSensitive: Bool
    /// Match only where the query is bounded by non-word characters (or the text's ends). Word characters
    /// are letters, digits and the underscore. Applies to a regular expression's matches too.
    public var wholeWord: Bool
    /// Read the query as a regular expression (ICU syntax, the one NSRegularExpression speaks) instead of
    /// literal text. `^` and `$` match at line boundaries and `.` stops at a newline, which is what a find
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

/// One hit: where it is in the rendered string, and a little context to show in a result list.
public struct RichTextMatch: Hashable, Sendable {
    /// UTF-16 range in the rendered string (NSString semantics, usable with TextKit directly).
    public let range: NSRange
    /// The line the match is on, trimmed to `snippetContext` characters on each side of the hit with an
    /// ellipsis where it was cut, whitespace collapsed and attachment placeholders dropped. The match
    /// itself is always kept whole.
    public let snippet: String
    /// Where the match sits inside `snippet` (UTF-16), so a result list can emphasize it - the snippet's
    /// whitespace collapsing makes this unrecoverable from `range` afterwards.
    public let rangeInSnippet: NSRange

    public init(range: NSRange, snippet: String, rangeInSnippet: NSRange) {
        self.range = range
        self.snippet = snippet
        self.rangeInSnippet = rangeInSnippet
    }
}

public enum RichTextSearch {

    /// Every non-overlapping match of `query` in `text`, in document order, ranges only - the cheap
    /// form for a find bar that shows a count and paints, and never displays a snippet. An empty (or
    /// all-whitespace) query matches nothing: a find bar being cleared must not light up the document.
    public static func ranges(in text: String, query: String,
                              options: RichTextSearchOptions = .default) -> [NSRange] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        if options.regularExpression {
            return regularExpressionRanges(in: text, pattern: query, options: options)
        }
        let haystack = text as NSString
        let length = haystack.length
        var compare: NSString.CompareOptions = []
        if !options.caseSensitive {
            compare.insert(.caseInsensitive)
        }
        if !options.diacriticSensitive {
            compare.insert(.diacriticInsensitive)
        }
        var result: [NSRange] = []
        var cursor = 0
        while cursor < length {
            if let limit = options.limit, result.count >= limit {
                break
            }
            let found = haystack.range(of: query, options: compare, range: NSRange(location: cursor, length: length - cursor))
            guard found.location != NSNotFound, found.length > 0 else {
                break
            }
            if !options.wholeWord || isWholeWord(found, in: haystack) {
                result.append(found)
                cursor = NSMaxRange(found)
            } else {
                // A rejected candidate may still contain the start of an accepted one ("kno no no" for
                // "no no"): move one character on, not past the whole candidate.
                cursor = NSMaxRange(haystack.rangeOfComposedCharacterSequence(at: found.location))
            }
        }
        return result
    }

    /// `ranges(in:query:options:)` plus a snippet per match, for a result list.
    public static func matches(in text: String, query: String,
                               options: RichTextSearchOptions = .default) -> [RichTextMatch] {
        let haystack = text as NSString
        return ranges(in: text, query: query, options: options).map { range in
            let (snippet, inSnippet) = snippet(around: range, in: haystack, context: options.snippetContext)
            return RichTextMatch(range: range, snippet: snippet, rangeInSnippet: inSnippet)
        }
    }

    /// The same over a rendered attributed string: ranges refer to `attributed.string`.
    public static func matches(in attributed: NSAttributedString, query: String,
                               options: RichTextSearchOptions = .default) -> [RichTextMatch] {
        matches(in: attributed.string, query: query, options: options)
    }

    /// Headless search over a document: renders it with `theme` / `engine` exactly as the view would, so
    /// the ranges are the ones `RichText.findHighlights` paints for the same document and theme. Pass the
    /// theme the view uses when the ranges will be handed to a view; for pure counting any theme does.
    public static func matches(in document: RichTextDocument, query: String,
                               options: RichTextSearchOptions = .default,
                               theme: RichTextTheme = .default,
                               engine: RichTextEngine = .textKit1) -> [RichTextMatch] {
        matches(in: RichTextAttributedString.make(document, theme: theme, engine: engine), query: query, options: options)
    }

    /// Whether `query` can be searched for at all: always for literal text, and for a regular expression
    /// only when the pattern compiles. A find bar shows "Invalid expression" instead of "No matches" when
    /// this is false, so a reader mid-way through typing `(foo|bar` is not told the document lacks it.
    public static func isValidQuery(_ query: String, options: RichTextSearchOptions = .default) -> Bool {
        guard options.regularExpression else {
            return true
        }
        return regexCache.regex(for: query, options: options) != nil
    }

    // MARK: - Regular expressions

    private static func regularExpressionRanges(in text: String, pattern: String,
                                                options: RichTextSearchOptions) -> [NSRange] {
        // Diacritic folding: NSRegularExpression has no diacritic-insensitive mode, so the text is folded up
        // front (the cache folds the pattern the same way) and each match is mapped back through the folded
        // text's origin map.
        guard let regex = regexCache.regex(for: pattern, options: options) else {
            return []
        }
        let folded: FoldedText? = options.diacriticSensitive ? nil : FoldedText.strippingDiacritics(from: text)
        let original = text as NSString
        let haystack = folded?.text ?? original
        let searched = folded?.string ?? text
        let length = haystack.length
        // No anchoring bounds, so `^` means a line start and not the resume point after the previous match;
        // transparent bounds make explicit that a lookbehind may look before that point too.
        let matching: NSRegularExpression.MatchingOptions = [.withTransparentBounds, .withoutAnchoringBounds]
        var result: [NSRange] = []
        var cursor = 0
        while cursor < length {
            if let limit = options.limit, result.count >= limit {
                break
            }
            guard let match = regex.firstMatch(in: searched, options: matching,
                                               range: NSRange(location: cursor, length: length - cursor)) else {
                break
            }
            let found = match.range
            // An empty match at the very end (`$`) is the last thing the pattern can find.
            guard found.location != NSNotFound, found.location < length else {
                break
            }
            let mapped = folded?.originalRange(found) ?? found
            if mapped.length > 0, !options.wholeWord || isWholeWord(mapped, in: original) {
                result.append(mapped)
                cursor = max(NSMaxRange(found), cursor + 1)
            } else {
                // An empty match, or a whole-word rejection: one character on, as in the literal search.
                cursor = NSMaxRange(haystack.rangeOfComposedCharacterSequence(at: found.location))
            }
        }
        return result
    }

    /// The last compiled pattern, keyed by the raw query and the options that shape the compile. A
    /// transcript search runs the engine once per message with the same query, and compiling an
    /// NSRegularExpression per message would cost more than the matching; one entry covers that, and a
    /// bar's keystroke replaces it. A pattern that failed to compile is remembered as nil, so a broken
    /// pattern is not re-parsed per message either. `isValidQuery` and the search share this, so the
    /// pattern the bar calls valid is the pattern that runs.
    private static let regexCache = RegexCache()

    private final class RegexCache: @unchecked Sendable {
        private let lock = NSLock()
        private var pattern: String?
        private var caseSensitive = true
        private var diacriticSensitive = true
        private var compiled: NSRegularExpression?

        func regex(for pattern: String, options: RichTextSearchOptions) -> NSRegularExpression? {
            lock.lock()
            defer { lock.unlock() }
            if pattern == self.pattern, options.caseSensitive == caseSensitive, options.diacriticSensitive == diacriticSensitive {
                return compiled
            }
            var flags: NSRegularExpression.Options = [.anchorsMatchLines]
            if !options.caseSensitive {
                flags.insert(.caseInsensitive)
            }
            // Under diacritic folding the pattern is folded like the text, so "resume" and
            // "r\u{e9}sum\u{e9}" are one pattern. The fold only rewrites non-ASCII scalars, so the pattern's
            // syntax survives; what changes is that a combining mark in the pattern is dropped, so a
            // quantifier after a decomposed accent binds to the base letter instead.
            let searched = options.diacriticSensitive ? pattern : FoldedText.strippingDiacritics(from: pattern).string
            self.pattern = pattern
            caseSensitive = options.caseSensitive
            diacriticSensitive = options.diacriticSensitive
            compiled = try? NSRegularExpression(pattern: searched, options: flags)
            return compiled
        }
    }

    /// A copy of a string with its diacritics stripped, plus the map from each UTF-16 unit of the copy back
    /// to the start of the original scalar it came from, so a range found in the copy is reported in the
    /// original. Folding is per scalar: a non-ASCII letter becomes its base letter, and every combining
    /// mark (categories Mn, Mc, Me - which includes the emoji presentation selector U+FE0F) is dropped, so
    /// decomposed text matches like precomposed text and the reported range extends over the mark. The
    /// map is exact.
    private struct FoldedText {
        let string: String
        let origin: [Int]
        let originalLength: Int

        var text: NSString {
            string as NSString
        }

        func originalRange(_ range: NSRange) -> NSRange {
            let end = NSMaxRange(range)
            let start = range.location < origin.count ? origin[range.location] : originalLength
            let mappedEnd = end < origin.count ? origin[end] : originalLength
            return NSRange(location: start, length: max(0, mappedEnd - start))
        }

        static func strippingDiacritics(from source: String) -> FoldedText {
            var units: [unichar] = []
            var origin: [Int] = []
            units.reserveCapacity(source.utf16.count)
            origin.reserveCapacity(source.utf16.count)
            var offset = 0
            for scalar in source.unicodeScalars {
                let width = scalar.utf16.count
                if scalar.isASCII {
                    units.append(unichar(scalar.value))
                    origin.append(offset)
                } else if !isMark(scalar) {
                    let piece = String(scalar).folding(options: .diacriticInsensitive, locale: nil)
                    for unit in piece.utf16 {
                        units.append(unit)
                        origin.append(offset)
                    }
                }
                offset += width
            }
            return FoldedText(string: String(utf16CodeUnits: units, count: units.count), origin: origin,
                              originalLength: offset)
        }

        private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Helpers

    private static let wordCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert("_")
        return set
    }()

    private static func isWholeWord(_ range: NSRange, in text: NSString) -> Bool {
        if range.location > 0, isWordCharacter(text.character(at: range.location - 1)) {
            return false
        }
        let end = NSMaxRange(range)
        if end < text.length, isWordCharacter(text.character(at: end)) {
            return false
        }
        return true
    }

    private static func isWordCharacter(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else {
            // A lone surrogate half: treat as a word character so a match never splits a surrogate pair.
            return true
        }
        return wordCharacters.contains(scalar)
    }

    /// The snippet and the match's range within it. Built by collapsing whitespace run by run while
    /// tracking where the match's two ends land, so the returned inner range is exact.
    private static func snippet(around range: NSRange, in text: NSString, context: Int) -> (String, NSRange) {
        // Stay on the match's own line: a snippet that runs into the next paragraph reads as nonsense.
        let lineRange = text.lineRange(for: range)
        var start = max(lineRange.location, range.location - max(0, context))
        var end = min(NSMaxRange(lineRange), NSMaxRange(range) + max(0, context))
        // Do not cut a surrogate pair or a composed sequence in half at either edge.
        start = text.rangeOfComposedCharacterSequence(at: start).location
        if end < text.length, end > start {
            end = NSMaxRange(text.rangeOfComposedCharacterSequence(at: end - 1))
        }

        let leadingCut = start > lineRange.location
        let trailingRest = NSRange(location: end, length: NSMaxRange(lineRange) - end)
        let trailingCut = trailingRest.length > 0
            && !text.substring(with: trailingRest).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        var out = leadingCut ? "..." : ""
        var matchStart: Int?
        var matchEnd: Int?
        var pendingSpace = false
        var index = start
        while index < end {
            if index == range.location {
                matchStart = (out as NSString).length + (pendingSpace ? 1 : 0)
            }
            if index == NSMaxRange(range) {
                matchEnd = (out as NSString).length
            }
            let unit = text.character(at: index)
            if unit == 0xFFFC {
                index += 1
                continue
            }
            let isSpace = (unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0xA0)
                || (Unicode.Scalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false)
            if isSpace {
                pendingSpace = !out.isEmpty || leadingCut
                index += 1
                continue
            }
            if pendingSpace {
                out += " "
                pendingSpace = false
            }
            out += String(utf16CodeUnits: [unit], count: 1)
            index += 1
        }
        if matchEnd == nil {
            matchEnd = (out as NSString).length
        }
        if trailingCut {
            out += "..."
        }
        let inner: NSRange
        if let matchStart, let matchEnd, matchEnd >= matchStart {
            inner = NSRange(location: matchStart, length: matchEnd - matchStart)
        } else {
            inner = NSRange(location: 0, length: 0)
        }
        return (out, inner)
    }
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
