// Sources/RichText/Gtk/RichTextSearch+Linux.swift
//
// The find engine on Linux: the counterpart of Search/RichTextSearch.swift, with the same options and rules, over
// GLib instead of NSString and NSRegularExpression (neither is in FoundationEssentials). Ranges are in
// characters - Unicode scalars - of the searched text, which is how GtkTextBuffer counts, so a match is directly
// a range of the view's buffer.
//
// Case folding is GLib's full case folding (g_utf8_casefold) and diacritic folding drops every combining mark
// after canonical decomposition (g_utf8_normalize), both per scalar with a map back to the original, so a match
// is reported over the original text (a dropped trailing mark is inside the range). Regular expressions are
// GRegex (PCRE2, with Unicode classes), matched against the whole text from a cursor so lookbehind sees past it.
// Where PCRE2 and ICU (NSRegularExpression on Apple platforms) differ: caseless matching does not fold "ss"
// against U+00DF or the ligatures (U+FB00-U+FB06), and ICU's \uXXXX and \N{name} escapes do not compile
// (PCRE2 writes a code point \x{XXXX}).

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import CRichTextGtk

/// One hit: where it is in the searched text, and a little context to show in a result list.
public struct RichTextMatch: Hashable, Sendable {
    /// Character (Unicode scalar) range in the searched text: a GtkTextBuffer offset range.
    public let range: Range<Int>
    /// The line the match is on, trimmed to `snippetContext` characters on each side of the hit with an
    /// ellipsis where it was cut, whitespace collapsed and attachment placeholders dropped. The match itself
    /// is always kept whole.
    public let snippet: String
    /// Where the match sits inside `snippet` (characters).
    public let rangeInSnippet: Range<Int>

    public init(range: Range<Int>, snippet: String, rangeInSnippet: Range<Int>) {
        self.range = range
        self.snippet = snippet
        self.rangeInSnippet = rangeInSnippet
    }
}

public enum RichTextSearch {

    /// Every non-overlapping match of `query` in `text`, in order, ranges only. An empty (or all-whitespace)
    /// query matches nothing: a find bar being cleared must not light up the document.
    public static func ranges(in text: String, query: String,
                              options: RichTextSearchOptions = .default) -> [Range<Int>] {
        // Blank as Foundation's whitespacesAndNewlines judges it on Apple platforms: White_Space plus U+200B.
        guard query.unicodeScalars.contains(where: { !$0.properties.isWhitespace && $0 != "\u{200B}" }) else {
            return []
        }
        let scalars = Array(text.unicodeScalars)
        if options.regularExpression {
            return regularExpressionRanges(in: scalars, pattern: query, options: options)
        }
        let haystack = Folded(scalars, caseFold: !options.caseSensitive, diacriticFold: !options.diacriticSensitive,
                              literal: true)
        let needle = Folded(Array(query.unicodeScalars), caseFold: !options.caseSensitive,
                            diacriticFold: !options.diacriticSensitive, literal: true).scalars
        guard !needle.isEmpty else {
            return []
        }
        var result: [Range<Int>] = []
        var cursor = 0
        while cursor + needle.count <= haystack.scalars.count {
            if let limit = options.limit, result.count >= limit {
                break
            }
            guard let start = haystack.firstIndex(of: needle, from: cursor) else {
                break
            }
            let end = start + needle.count
            // A match must start and end on an original scalar's boundary ("s" never matches half of "ss" from
            // a folded U+00DF sharp s). Where marks are kept it must not end before one either: a diacritic-sensitive "e"
            // is not the base of a decomposed "e\u{301}".
            let endsBeforeMark = options.diacriticSensitive && end < haystack.scalars.count
                && isCombining(haystack.scalars[end])
            if haystack.isBoundary(start), haystack.isBoundary(end), !endsBeforeMark {
                let mapped = haystack.originalRange(start..<end)
                if !options.wholeWord || isWholeWord(mapped, in: scalars) {
                    result.append(mapped)
                    cursor = end
                    continue
                }
            }
            // Rejected: one folded scalar on, as a rejected candidate may hold the start of an accepted one.
            cursor = start + 1
        }
        return result
    }

    /// `ranges(in:query:options:)` plus a snippet per match, for a result list.
    public static func matches(in text: String, query: String,
                               options: RichTextSearchOptions = .default) -> [RichTextMatch] {
        let characters = Array(text)
        let ranges = ranges(in: text, query: query, options: options)
        guard !ranges.isEmpty else {
            return []
        }
        // Each Character's first scalar offset, so a snippet never splits a Character.
        var starts: [Int] = []
        starts.reserveCapacity(characters.count + 1)
        var offset = 0
        for character in characters {
            starts.append(offset)
            offset += character.unicodeScalars.count
        }
        starts.append(offset)
        return ranges.map { range in
            let (snippet, inSnippet) = snippet(around: range, characters: characters, starts: starts,
                                               context: options.snippetContext)
            return RichTextMatch(range: range, snippet: snippet, rangeInSnippet: inSnippet)
        }
    }

    /// Whether `query` can be searched for at all: always for literal text, and for a regular expression only
    /// when the pattern compiles.
    public static func isValidQuery(_ query: String, options: RichTextSearchOptions = .default) -> Bool {
        guard options.regularExpression else {
            return true
        }
        return regexCache.regex(for: query, options: options) != nil
    }

    // MARK: - Folding

    // A copy of the text's scalars, folded, with the original scalar each came from.
    struct Folded {
        var scalars: [Unicode.Scalar] = []
        var origin: [Int] = []
        let originalCount: Int

        // `literal`: decomposed even when marks are kept, so precomposed and decomposed text compare equal as
        // NSString's literal search has them (a regular expression, like NSRegularExpression, sees the text as is).
        init(_ source: [Unicode.Scalar], caseFold: Bool, diacriticFold: Bool, literal: Bool = false) {
            originalCount = source.count
            scalars.reserveCapacity(source.count)
            origin.reserveCapacity(source.count)
            for (index, scalar) in source.enumerated() {
                for piece in Self.fold(scalar, caseFold: caseFold, diacriticFold: diacriticFold, literal: literal) {
                    scalars.append(piece)
                    origin.append(index)
                }
            }
        }

        // One scalar folded: ASCII directly, anything else through GLib (decomposed, marks dropped, case-folded).
        static func fold(_ scalar: Unicode.Scalar, caseFold: Bool, diacriticFold: Bool,
                         literal: Bool) -> [Unicode.Scalar] {
            if scalar.isASCII {
                if caseFold, ("A"..."Z").contains(scalar) {
                    return [Unicode.Scalar(scalar.value + 32)!]
                }
                return [scalar]
            }
            if diacriticFold, RichTextSearch.isMark(scalar) {
                return []
            }
            var pieces = [scalar]
            if diacriticFold || literal {
                pieces = glib(String(scalar)) { g_utf8_normalize($0, -1, G_NORMALIZE_NFD) }
            }
            if diacriticFold {
                pieces = pieces.filter { !RichTextSearch.isMark($0) }
                // What a regular expression sees stays one character per character: a Hangul syllable, which
                // decomposes into its two or three letters (jamo), is put back together so `.` matches all of it.
                if !literal, pieces.count > 1 {
                    pieces = glib(String(String.UnicodeScalarView(pieces))) { g_utf8_normalize($0, -1, G_NORMALIZE_NFC) }
                }
            }
            if caseFold {
                pieces = pieces.flatMap { piece in glib(String(piece)) { g_utf8_casefold($0, -1) } }
            }
            return pieces
        }

        // The scalars of a GLib function's newly allocated UTF-8 result.
        private static func glib(_ text: String, _ call: (UnsafePointer<CChar>) -> UnsafeMutablePointer<gchar>?)
            -> [Unicode.Scalar] {
            guard let result = text.withCString({ call($0) }) else {
                return Array(text.unicodeScalars)
            }
            defer {
                g_free(result)
            }
            return Array(String(cString: result).unicodeScalars)
        }

        func firstIndex(of needle: [Unicode.Scalar], from start: Int) -> Int? {
            guard needle.count <= scalars.count else {
                return nil
            }
            var index = start
            while index + needle.count <= scalars.count {
                if scalars[index] == needle[0], scalars[index..<(index + needle.count)].elementsEqual(needle) {
                    return index
                }
                index += 1
            }
            return nil
        }

        // Whether a folded index is where an original scalar's folding begins (or the end).
        func isBoundary(_ index: Int) -> Bool {
            index == 0 || index >= scalars.count || origin[index - 1] != origin[index]
        }

        // A folded range in original scalars: from its first scalar's origin to the next folded scalar's origin
        // (so dropped marks after the match are inside it), or to the end.
        func originalRange(_ range: Range<Int>) -> Range<Int> {
            let start = range.lowerBound < origin.count ? origin[range.lowerBound] : originalCount
            let end = range.upperBound < origin.count ? origin[range.upperBound] : originalCount
            return start..<max(start, end)
        }
    }

    static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }

    // A nonspacing or enclosing mark: what NSString keeps with the character before it. A spacing mark (a
    // Devanagari vowel sign) is not, there.
    static func isCombining(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }

    // MARK: - Regular expressions

    private static func regularExpressionRanges(in scalars: [Unicode.Scalar], pattern: String,
                                                options: RichTextSearchOptions) -> [Range<Int>] {
        guard let regex = regexCache.regex(for: pattern, options: options) else {
            return []
        }
        // Diacritic folding: the text is folded like the pattern (the cache folds it), and each match is mapped
        // back through the fold. Case folding is the regex's own caseless mode.
        let folded = Folded(scalars, caseFold: false, diacriticFold: !options.diacriticSensitive)
        let searched = String(String.UnicodeScalarView(folded.scalars))
        // The UTF-8 byte offset where each folded scalar starts, and the end.
        var byteStarts: [Int] = []
        byteStarts.reserveCapacity(folded.scalars.count + 1)
        var bytes = 0
        for scalar in folded.scalars {
            byteStarts.append(bytes)
            bytes += UTF8.width(scalar)
        }
        byteStarts.append(bytes)
        func scalarIndex(ofByte byte: Int) -> Int {
            var low = 0
            var high = byteStarts.count - 1
            while low < high {
                let middle = (low + high) / 2
                if byteStarts[middle] < byte {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return low
        }

        var result: [Range<Int>] = []
        var cursor = 0   // folded scalar index
        searched.withCString { text in
            while cursor < folded.scalars.count {
                if let limit = options.limit, result.count >= limit {
                    break
                }
                var info: OpaquePointer?
                var error: UnsafeMutablePointer<GError>?
                let found = g_regex_match_full(regex.pointer, text, gssize(bytes), gint(byteStarts[cursor]),
                                               GRegexMatchFlags(rawValue: 0), &info, &error)
                if let error {
                    g_error_free(error)
                }
                defer {
                    g_match_info_free(info)
                }
                var startByte: gint = -1
                var endByte: gint = -1
                guard found != 0, g_match_info_fetch_pos(info, 0, &startByte, &endByte) != 0 else {
                    break
                }
                let start = scalarIndex(ofByte: Int(startByte))
                let end = scalarIndex(ofByte: Int(endByte))
                // An empty match at the very end ($) is the last thing the pattern can find.
                guard start < folded.scalars.count else {
                    break
                }
                let mapped = folded.originalRange(start..<end)
                if !mapped.isEmpty, !options.wholeWord || isWholeWord(mapped, in: scalars) {
                    result.append(mapped)
                    cursor = max(end, cursor + 1)
                } else {
                    // An empty match, or a whole-word rejection: one scalar on.
                    cursor = start + 1
                }
            }
        }
        return result
    }

    // A compiled pattern, released with the last reference (the cache may replace it while a search uses it).
    final class CompiledRegex: @unchecked Sendable {
        let pointer: OpaquePointer
        init(adopting pointer: OpaquePointer) {
            self.pointer = pointer
        }
        deinit {
            g_regex_unref(pointer)
        }
    }

    /// The last compiled pattern, keyed by the raw query and the options that shape the compile; a broken
    /// pattern is remembered as nil. `isValidQuery` and the search share it, so the pattern a bar calls valid
    /// is the pattern that runs.
    private static let regexCache = RegexCache()

    private final class RegexCache: Sendable {
        private struct Entry {
            var pattern: String
            var caseSensitive: Bool
            var diacriticSensitive: Bool
            var compiled: CompiledRegex?
        }
        private let entry = Mutex<Entry?>(nil)

        func regex(for pattern: String, options: RichTextSearchOptions) -> CompiledRegex? {
            entry.withLock { entry -> CompiledRegex? in
                if let entry, entry.pattern == pattern, entry.caseSensitive == options.caseSensitive,
                   entry.diacriticSensitive == options.diacriticSensitive {
                    return entry.compiled
                }
                // Under diacritic folding the pattern is folded like the text; the fold rewrites only non-ASCII
                // scalars, so the pattern's syntax survives (a combining mark in it is dropped).
                let searched = options.diacriticSensitive ? pattern
                    : String(String.UnicodeScalarView(Folded(Array(pattern.unicodeScalars), caseFold: false,
                                                             diacriticFold: true).scalars))
                // G_REGEX_OPTIMIZE compiles the pattern to machine code (PCRE2's JIT). Without it every match
                // call re-validates the UTF-8 from the cursor to the end of the text, so a search is quadratic
                // in the text (about 1 s for 40,000 matches in 200 KB, against 11 ms with it).
                var flags = RICHTEXT_G_REGEX_MULTILINE | RICHTEXT_G_REGEX_OPTIMIZE
                if !options.caseSensitive {
                    flags |= RICHTEXT_G_REGEX_CASELESS
                }
                var error: UnsafeMutablePointer<GError>?
                // An empty pattern (or one of marks only, folded away) is invalid, as NSRegularExpression has it.
                let made = searched.isEmpty ? nil
                    : g_regex_new(searched, GRegexCompileFlags(rawValue: flags), GRegexMatchFlags(rawValue: 0), &error)
                if let error {
                    g_error_free(error)
                }
                if let made {
                    // GLib compiles the machine code on the first match, writing to the shared GRegex: do it here,
                    // under the lock, so two searches starting at once never race on it (later matches only read).
                    _ = g_regex_match(made, "", GRegexMatchFlags(rawValue: 0), nil)
                }
                let compiled = made.map { CompiledRegex(adopting: $0) }
                entry = Entry(pattern: pattern, caseSensitive: options.caseSensitive,
                              diacriticSensitive: options.diacriticSensitive, compiled: compiled)
                return compiled
            }
        }
    }

    // MARK: - Helpers

    // Word characters: letters, marks, digits (CharacterSet.alphanumerics) and the underscore.
    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "_" {
            return true
        }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    private static func isWholeWord(_ range: Range<Int>, in scalars: [Unicode.Scalar]) -> Bool {
        if range.lowerBound > 0, isWordScalar(scalars[range.lowerBound - 1]) {
            return false
        }
        if range.upperBound < scalars.count, isWordScalar(scalars[range.upperBound]) {
            return false
        }
        return true
    }

    // The snippet and the match's range within it (characters), built by collapsing whitespace run by run while
    // tracking where the match's two ends land.
    private static func snippet(around range: Range<Int>, characters: [Character], starts: [Int],
                                context: Int) -> (String, Range<Int>) {
        // The Characters holding the match: the one its first scalar is in, through the one its last is in.
        func characterIndex(atScalar offset: Int) -> Int {
            var low = 0
            var high = starts.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if starts[middle] <= offset {
                    low = middle
                } else {
                    high = middle - 1
                }
            }
            return low
        }
        let matchStart = characterIndex(atScalar: range.lowerBound)
        let matchEnd = range.isEmpty ? matchStart : characterIndex(atScalar: range.upperBound - 1) + 1
        // Stay on the match's own line, looking no further than the context: scanning to the line's ends would
        // make every snippet cost the line's length, quadratic over a long line with many matches.
        let context = max(0, context)
        var start = matchStart
        while start > 0, matchStart - start < context, !characters[start - 1].isNewline {
            start -= 1
        }
        var end = matchEnd
        while end < characters.count, end - matchEnd < context, !characters[end].isNewline {
            end += 1
        }
        let leadingCut = start > 0 && !characters[start - 1].isNewline
        // Cut when anything but whitespace follows on the line.
        var rest = end
        while rest < characters.count, !characters[rest].isNewline, characters[rest].isWhitespace {
            rest += 1
        }
        let trailingCut = rest < characters.count && !characters[rest].isNewline

        var out = leadingCut ? "..." : ""
        var count = out.unicodeScalars.count
        var innerStart: Int?
        var innerEnd: Int?
        var pendingSpace = false
        for index in start..<end {
            if index == matchStart {
                innerStart = count + (pendingSpace ? 1 : 0)
            }
            if index == matchEnd {
                innerEnd = count
            }
            let character = characters[index]
            if character == "\u{FFFC}" {
                continue
            }
            if character.isWhitespace {
                pendingSpace = !out.isEmpty || leadingCut
                continue
            }
            if pendingSpace {
                out += " "
                count += 1
                pendingSpace = false
            }
            out.append(character)
            count += character.unicodeScalars.count
        }
        let finalEnd = innerEnd ?? count
        if trailingCut {
            out += "..."
        }
        let finalStart = innerStart ?? 0
        return (out, finalStart..<max(finalStart, finalEnd))
    }
}
