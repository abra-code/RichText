// Sources/RichText/Markdown/RichTextAutolinker.swift
//
// A post-pass over inline nodes that turns bare URLs and email addresses in plain text into links (GFM's
// autolink extension), so a URL typed without [](...) is still tappable. It runs after inline parsing,
// walking only `.text` nodes and recursing into emphasis / strong / strikethrough - it deliberately does
// NOT touch `.code` or an existing `.link` (so a URL inside inline code, or the visible text of a real
// link, is left alone).
//
// The rules are those of cmark-gfm's autolink extension, the parser behind Apple's
// AttributedString(markdown:), so a bare URL links where it does in SwiftUI's Text:
// - http://, https:// and ftp:// URLs, and www. hosts (lower case, after a space, a line start or one of
//   * _ ~ ( ), which get http://; a bare domain such as example.com stays text.
// - email addresses, which get mailto:, and mailto: and xmpp: addresses as written.
// - the URL runs to a space or a '<', then trailing ? ! . , : * _ ~ ' " are dropped, an unbalanced ')',
//   and a trailing entity-like "&name;".
// - a host with an underscore in one of its last two labels is not linked, unless it has more than 10 labels.
//
// Written with the standard library only, so it also builds where Foundation is not used (Linux).

enum RichTextAutolinker {

    static func link(_ nodes: [RichTextInline]) -> [RichTextInline] {
        var result: [RichTextInline] = []
        var index = 0
        while index < nodes.count {
            switch nodes[index] {
            case .text:
                // Adjacent text nodes are scanned as one text, as a URL may span them.
                var end = index
                var text = ""
                while end < nodes.count, case .text(let piece) = nodes[end] {
                    text += piece
                    end += 1
                }
                let linked = split(text, wwwAllowedAtStart: wwwMayFollow(index == 0 ? nil : nodes[index - 1]))
                if linked.count == 1, case .text = linked[0] {
                    result.append(contentsOf: nodes[index..<end])
                } else {
                    result.append(contentsOf: linked)
                }
                index = end
            case .emphasis(let children):
                result.append(.emphasis(link(children)))
                index += 1
            case .strong(let children):
                result.append(.strong(link(children)))
                index += 1
            case .strikethrough(let children):
                result.append(.strikethrough(link(children)))
                index += 1
            case .code, .link, .image, .lineBreak:
                result.append(nodes[index])
                index += 1
            }
        }
        return result
    }

    // Whether a www. host at the start of a text may link after `previous`: cmark-gfm allows one after a
    // line start, a space, or * _ ~ (, which is what precedes text that begins a paragraph or an emphasis
    // span or follows one; not after the backtick of a code span or the ')' of a link or image.
    private static func wwwMayFollow(_ previous: RichTextInline?) -> Bool {
        switch previous {
        case nil, .emphasis, .strong, .strikethrough, .lineBreak:
            return true
        case .text, .code, .link, .image:
            return false
        }
    }

    // MARK: Splitting a text

    private struct Found {
        var start: Int
        var end: Int
        var url: String
    }

    private static func split(_ text: String, wwwAllowedAtStart: Bool) -> [RichTextInline] {
        let scalars = Array(text.unicodeScalars)
        var found: [Found] = []
        // URLs and www. hosts, left to right, as cmark-gfm finds them while it parses the line.
        var position = 0
        var segmentStart = 0
        while position < scalars.count {
            let c = scalars[position]
            var match: Found?
            if c == ":" {
                match = urlMatch(scalars, colon: position, from: segmentStart)
            } else if c == "w" {
                let allowed = position == 0 ? wwwAllowedAtStart : wwwMayFollow(scalars[position - 1])
                match = allowed ? wwwMatch(scalars, at: position) : nil
            }
            if let match {
                found.append(match)
                position = match.end
                segmentStart = match.end
            } else {
                position += 1
            }
        }
        // Then email addresses, in the text left between them (cmark-gfm's pass after parsing).
        var all: [Found] = []
        var cursor = 0
        for link in found + [Found(start: scalars.count, end: scalars.count, url: "")] {
            all += emailMatches(scalars, from: cursor, to: link.start)
            if link.start < link.end {
                all.append(link)
            }
            cursor = link.end
        }
        if all.isEmpty {
            return [.text(text)]
        }
        var result: [RichTextInline] = []
        cursor = 0
        for link in all {
            if link.start > cursor {
                result.append(.text(string(scalars[cursor..<link.start])))
            }
            result.append(.link(text: [.text(string(scalars[link.start..<link.end]))], url: link.url))
            cursor = link.end
        }
        if cursor < scalars.count {
            result.append(.text(string(scalars[cursor...])))
        }
        return result
    }

    private static func wwwMayFollow(_ c: Unicode.Scalar) -> Bool {
        return c == "*" || c == "_" || c == "~" || c == "(" || isSpace(c)
    }

    // MARK: Matchers (cmark-gfm's extensions/autolink.c)

    // A URL whose "://" starts at `colon`: the scheme is the letters before it (not before `from`, the end
    // of the previous link), and must be http, https or ftp.
    private static func urlMatch(_ s: [Unicode.Scalar], colon: Int, from: Int) -> Found? {
        guard colon + 3 < s.count, s[colon + 1] == "/", s[colon + 2] == "/" else {
            return nil
        }
        var start = colon
        while start > from, isAlpha(s[start - 1]) {
            start -= 1
        }
        let scheme = string(s[start..<colon]).lowercased()
        guard scheme == "http" || scheme == "https" || scheme == "ftp", isHostChar(s[colon + 3]) else {
            return nil
        }
        guard let domain = domainLength(s, from: colon + 3, allowShort: true) else {
            return nil
        }
        var end = colon + 3 + domain
        while end < s.count, !isSpace(s[end]), s[end] != "<" {
            end += 1
        }
        end = trimmedEnd(s, start: start, end: end)
        let url = string(s[start..<end])
        return Found(start: start, end: end, url: url)
    }

    private static func wwwMatch(_ s: [Unicode.Scalar], at start: Int) -> Found? {
        guard start + 4 <= s.count, s[start] == "w", s[start + 1] == "w", s[start + 2] == "w", s[start + 3] == "." else {
            return nil
        }
        guard let domain = domainLength(s, from: start, allowShort: false) else {
            return nil
        }
        var end = start + domain
        while end < s.count, !isSpace(s[end]), s[end] != "<" {
            end += 1
        }
        end = trimmedEnd(s, start: start, end: end)
        guard end > start else {
            return nil
        }
        return Found(start: start, end: end, url: "http://" + string(s[start..<end]))
    }

    // The length of the host at `from` (its first character is taken as valid), or nil when an underscore
    // is in one of its last two labels, or when `allowShort` is false and it has no dot. Like cmark-gfm's
    // check_domain, it never looks at the text's last character.
    private static func domainLength(_ s: [Unicode.Scalar], from: Int, allowShort: Bool) -> Int? {
        let size = s.count - from
        var i = 1
        var dots = 0
        var underscoresBefore = 0
        var underscores = 0
        while i < size - 1 {
            if s[from + i] == "\\", i < size - 2 {
                i += 1
            }
            let c = s[from + i]
            if c == "_" {
                underscores += 1
            } else if c == "." {
                underscoresBefore = underscores
                underscores = 0
                dots += 1
            } else if !isHostChar(c), c != "-" {
                break
            }
            i += 1
        }
        // A host of more than 10 labels is taken despite the underscores, as cmark-gfm does: without this a
        // run of "_www." hosts makes the scan quadratic.
        if underscoresBefore > 0 || underscores > 0, dots <= 10 {
            return nil
        }
        if !allowShort, dots == 0 {
            return nil
        }
        return max(i, 1)
    }

    // Where a link from `start` to `end` really ends: before any '<', without trailing punctuation, an
    // unbalanced ')' or a trailing "&name;" (cmark-gfm's autolink_delim).
    private static func trimmedEnd(_ s: [Unicode.Scalar], start: Int, end: Int) -> Int {
        var end = end
        if let angle = s[start..<end].firstIndex(of: "<") {
            end = angle
        }
        var opening = 0
        var closing = 0
        for c in s[start..<end] {
            if c == "(" {
                opening += 1
            } else if c == ")" {
                closing += 1
            }
        }
        while end > start {
            let last = s[end - 1]
            if "?!.,:*_~'\"".unicodeScalars.contains(last) {
                end -= 1
            } else if last == ";" {
                var entityStart = end - 2
                while entityStart > start, isAlpha(s[entityStart]) {
                    entityStart -= 1
                }
                if entityStart < end - 2, s[entityStart] == "&" {
                    end = entityStart
                } else {
                    end -= 1
                }
            } else if last == ")", closing > opening {
                // Only a ')' changes the counts: the other dropped characters are not brackets.
                closing -= 1
                end -= 1
            } else {
                break
            }
        }
        return end
    }

    // Email addresses in s[from..<to] (cmark-gfm's postprocess_text): local part letters, digits and
    // . + - _, a domain of letters, digits, - and _ with a dot followed by a letter or digit, ending in a
    // letter or a dot (dropped). "mailto:" or "xmpp:" right before the local part is kept in the link.
    private static func emailMatches(_ s: [Unicode.Scalar], from: Int, to: Int) -> [Found] {
        var result: [Found] = []
        var offset = from
        while offset < to {
            guard let at = s[offset..<to].firstIndex(of: "@") else {
                break
            }
            var rewind = 0
            var autoMailto = true
            var isXMPP = false
            while at - rewind > offset {
                let c = s[at - rewind - 1]
                if isAlnum(c) || ".+-_".unicodeScalars.contains(c) {
                    rewind += 1
                    continue
                }
                if c == ":" {
                    if hasProtocol("mailto:", s, before: at - rewind, from: offset) {
                        autoMailto = false
                        rewind += 1
                        continue
                    }
                    if hasProtocol("xmpp:", s, before: at - rewind, from: offset) {
                        autoMailto = false
                        isXMPP = true
                        rewind += 1
                        continue
                    }
                }
                break
            }
            if rewind == 0 {
                offset = at + 1
                continue
            }
            var end = at
            var ats = 0
            var dots = 0
            while end < to {
                let c = s[end]
                if isAlnum(c) {
                    end += 1
                    continue
                }
                if c == "@" {
                    ats += 1
                    if ats > 1 {
                        // No address now: stopping here keeps a long run of @s linear.
                        break
                    }
                } else if c == ".", end < to - 1, isAlnum(s[end + 1]) {
                    dots += 1
                } else if c == "/", isXMPP {
                    end += 1
                    continue
                } else if c != "-", c != "_" {
                    break
                }
                end += 1
            }
            let length = end - at
            if length < 2 || ats != 1 || dots == 0 || (!isAlpha(s[end - 1]) && s[end - 1] != ".") {
                offset = at + 1
                continue
            }
            end = trimmedEnd(s, start: at, end: end)
            if end == at {
                offset = at + 1
                continue
            }
            let start = at - rewind
            let address = string(s[start..<end])
            result.append(Found(start: start, end: end, url: autoMailto ? "mailto:" + address : address))
            offset = end
        }
        return result
    }

    // Whether `name` ("mailto:") ends right before `before`, at `from` or after a character that is not a
    // letter or digit.
    private static func hasProtocol(_ name: String, _ s: [Unicode.Scalar], before: Int, from: Int) -> Bool {
        let length = name.unicodeScalars.count
        let start = before - length
        guard start >= from, string(s[start..<before]) == name else {
            return false
        }
        return start == from || !isAlnum(s[start - 1])
    }

    // MARK: Character classes (cmark's, which are ASCII but for the host characters)

    private static func isAlpha(_ c: Unicode.Scalar) -> Bool {
        return (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
    }

    private static func isAlnum(_ c: Unicode.Scalar) -> Bool {
        return isAlpha(c) || (c >= "0" && c <= "9")
    }

    private static func isSpace(_ c: Unicode.Scalar) -> Bool {
        return c == " " || (c.value >= 9 && c.value <= 13)
    }

    // A host character: not white space and not punctuation, in Unicode's sense.
    private static func isHostChar(_ c: Unicode.Scalar) -> Bool {
        if c.isASCII {
            return !isSpace(c) && !"!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".unicodeScalars.contains(c)
        }
        switch c.properties.generalCategory {
        case .spaceSeparator, .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return false
        default:
            return true
        }
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}
