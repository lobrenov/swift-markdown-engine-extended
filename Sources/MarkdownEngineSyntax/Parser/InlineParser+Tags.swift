//
//  InlineParser+Tags.swift
//  MarkdownEngineSyntax
//
//  Fork: `#tags`, scanned in `InlineParser`'s pass 3b when the registry reads them.
//

import Foundation

public enum TagSyntax {
    /// A character a tag's name may hold: a letter, a digit, `_`, `-` or `/`.
    public static func isTagCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "-" || c == "/"
    }
}

extension InlineParser {
    /// `#` at the text's start (when `startsAtBoundary`) or after whitespace, then letters, digits, `_`, `-` and `/`,
    /// with at least one character that isn't a digit or `/`. Trailing `/`s stay
    /// out of the span. Escaped and claimed `#`s are skipped. A `#` after a run of `*` or `_` takes the boundary of the
    /// run's start; such tags are also returned by start, to keep only where the run opens emphasis, and leave as many
    /// trailing `_`s as the run had for its closer.
    static func scanTags(_ ns: NSString, len: Int, claimed: inout ClaimedIndex, startsAtBoundary: Bool)
        -> (spans: [Span], afterDelimiters: Set<Int>) {
        var spans: [Span] = []
        var afterDelimiters: Set<Int> = []
        var i = 0
        while i < len {
            guard ns.character(at: i) == hash, !claimed.contains(i),
                  let delimiters = tagBoundary(before: i, ns, startsAtBoundary) else {
                i += 1
                continue
            }
            var end = i + 1
            var hasWord = false
            while end < len {
                let composed = ns.rangeOfComposedCharacterSequence(at: end)
                guard let c = ns.substring(with: composed).first, TagSyntax.isTagCharacter(c) else { break }
                if !c.isNumber && c != "/" { hasWord = true }
                end = NSMaxRange(composed)
            }
            let scanned = end
            var underscores = delimiters.underscores
            while underscores > 0, end > i + 1, ns.character(at: end - 1) == underscore {
                end -= 1
                underscores -= 1
            }
            while end > i + 1, ns.character(at: end - 1) == 0x2F { end -= 1 }
            let range = NSRange(location: i, length: end - i)
            let name = ns.substring(with: NSRange(location: i + 1, length: end - i - 1))
            if hasWord, name.contains(where: { !$0.isNumber && $0 != "/" }), !claimed.overlaps(range) {
                spans.append(.tag(range: range, marker: NSRange(location: i, length: 1)))
                if delimiters.count > 0 { afterDelimiters.insert(i) }
            }
            i = scanned
        }
        return (spans, afterDelimiters)
    }

    /// The run of `*` and `_` before `i` when whitespace (by `Character.isWhitespace`) or the
    /// text's start (when `startsAtBoundary`) comes before the run; nil when the `#` isn't at a boundary.
    private static func tagBoundary(before i: Int, _ ns: NSString, _ startsAtBoundary: Bool)
        -> (count: Int, underscores: Int)? {
        var k = i - 1
        var underscores = 0
        while k >= 0, ns.character(at: k) == asterisk || ns.character(at: k) == underscore {
            if ns.character(at: k) == underscore { underscores += 1 }
            k -= 1
        }
        let atBoundary = k < 0
            ? startsAtBoundary
            : Unicode.Scalar(ns.character(at: k)).map { Character($0).isWhitespace } ?? false
        return atBoundary ? (i - 1 - k, underscores) : nil
    }
}
