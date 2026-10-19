//
//  MarkdownAutoPairs.swift
//  MarkdownEngine
//
//  Fork: auto-closed brackets, formatting markers and wiki links. The
//  editor remembers each closer it adds, so typing that closer steps over it.
//

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// A pair the editor closed: the typed `opener` and the `closer` it added after the caret.
struct AutoPair: Equatable {
    var opener: NSRange
    var closer: NSRange
}

enum MarkdownAutoPairs {

    /// Formatting markers, with the shortest run that opens a pair and the longest.
    static let markers: [Character: (shortest: Int, longest: Int)] = [
        "*": (1, 2), "_": (1, 2), "~": (2, 2), "=": (2, 2), "`": (1, 1)
    ]
    static let brackets: [Character: Character] = ["(": ")", "[": "]", "{": "}"]
    /// Characters `handleInsertion` acts on.
    static let triggers: Set<Character> = Set(markers.keys).union(brackets.keys).union([")", "]", "}"])

    /// The pairs after an applied edit: pairs after it move, and a pair it touches is forgotten.
    static func map(_ pairs: [AutoPair], replacing range: NSRange, with length: Int) -> [AutoPair] {
        let delta = length - range.length
        func moved(_ r: NSRange) -> NSRange? {
            if NSMaxRange(range) <= r.location { return NSRange(location: r.location + delta, length: r.length) }
            if range.location >= NSMaxRange(r) { return r }
            return nil
        }
        return pairs.compactMap { pair in
            guard let opener = moved(pair.opener), let closer = moved(pair.closer) else { return nil }
            return AutoPair(opener: opener, closer: closer)
        }
    }

    /// The pairs that still hold the caret between opener and closer.
    static func keeping(_ pairs: [AutoPair], selection: NSRange) -> [AutoPair] {
        guard selection.length == 0 else { return [] }
        return pairs.filter { NSMaxRange($0.opener) <= selection.location && selection.location <= $0.closer.location }
    }

    /// Handles a typed opener, closer, marker or space. `nil` leaves the keystroke to the caller.
    static func handleInsertion(_ textView: PlatformTextView, range: NSRange, replacement: String, isInCodeBlock: Bool) -> Bool? {
        guard replacement.utf16.count == 1, let typed = replacement.first,
              triggers.contains(typed) || typed == " " else { return nil }
        let native = textView as? NativeTextView
        let lists = native?.configuration.lists ?? MarkdownEditorConfiguration.default.lists
        let text = textView.string as NSString
        let location = range.location

        func character(at index: Int) -> Character? {
            guard index >= 0, index < text.length else { return nil }
            return Character(text.substring(with: NSRange(location: index, length: 1)))
        }
        func run(of c: Character, in r: NSRange) -> Bool {
            r.length > 0 && NSMaxRange(r) <= text.length && text.substring(with: r) == String(repeating: c, count: r.length)
        }
        func replace(_ r: NSRange, with string: String, caret: Int, pair: AutoPair?) -> Bool {
            MarkdownLists.performEdit(textView, replace: r, with: string)
            if let pair { native?.autoPairs.append(pair) }
            textView.setSelectedRange(NSRange(location: caret, length: 0))
            return false
        }

        if range.length == 0, let native,
           let index = native.autoPairs.lastIndex(where: { $0.closer.location == location }) {
            let pair = native.autoPairs[index]
            let isEmptyMarkerPair = NSMaxRange(pair.opener) == location
                && markers.keys.contains { run(of: $0, in: pair.opener) && run(of: $0, in: pair.closer) }
            // A space after a marker can't open formatting (`2 * 3`, `a == b`), so the closer goes.
            if typed == " ", isEmptyMarkerPair {
                native.autoPairs.remove(at: index)
                return replace(pair.closer, with: " ", caret: location + 1, pair: nil)
            }
            // A marker typed in an empty marker pair lengthens it, or past the longest, leaves the run unpaired.
            if let lengths = markers[typed], isEmptyMarkerPair, run(of: typed, in: pair.opener) {
                native.autoPairs.remove(at: index)
                let count = pair.opener.length + 1
                let whole = NSRange(location: pair.opener.location, length: pair.opener.length + pair.closer.length)
                let marker = String(repeating: typed, count: count)
                guard count <= lengths.longest else {
                    return replace(whole, with: marker, caret: whole.location + count, pair: nil)
                }
                return replace(whole, with: marker + marker, caret: whole.location + count,
                               pair: AutoPair(opener: NSRange(location: whole.location, length: count),
                                              closer: NSRange(location: whole.location + count, length: count)))
            }
            // A closer the editor added is stepped over.
            if character(at: location) == typed {
                if pair.closer.length > 1 {
                    native.autoPairs[index].closer = NSRange(location: location + 1, length: pair.closer.length - 1)
                } else {
                    native.autoPairs.remove(at: index)
                }
                textView.setSelectedRange(NSRange(location: location + 1, length: 0))
                return false
            }
        }
        if typed == " " { return nil }

        // `[[` (and `![[`) completes to `[[]]`.
        if typed == "[", lists.autoCloseWikiLinksEnabled, range.length == 0, character(at: location - 1) == "[" {
            let opener = NSRange(location: location - 1, length: 2)
            let closer = NSRange(location: location + 1, length: 2)
            if character(at: location) == "]" {
                return replace(NSRange(location: location - 1, length: 2), with: "[[]]", caret: location + 1,
                               pair: AutoPair(opener: opener, closer: closer))
            }
            return replace(range, with: "[]]", caret: location + 1, pair: AutoPair(opener: opener, closer: closer))
        }

        if let close = brackets[typed] {
            guard lists.autoClosePairsEnabled else { return nil }
            return replace(range, with: "\(typed)\(close)", caret: location + 1,
                           pair: AutoPair(opener: NSRange(location: location, length: 1),
                                          closer: NSRange(location: location + 1, length: 1)))
        }

        guard let lengths = markers[typed], lists.autoCloseFormattingEnabled, range.length == 0, !isInCodeBlock else {
            return nil
        }
        var start = location
        while character(at: start - 1) == typed { start -= 1 }
        let count = location - start + 1
        guard count >= lengths.shortest, count <= lengths.longest else { return nil }
        // Pairs only between words: not after a letter or digit (`snake_case`, `2*3`), nor before one.
        func isWordCharacter(_ c: Character?) -> Bool { c.map { $0.isLetter || $0.isNumber } ?? false }
        let after = character(at: location)
        guard !isWordCharacter(character(at: start - 1)), !isWordCharacter(after), after != typed else { return nil }
        // A single `*` at a line's start is a bullet.
        if typed == "*", count == 1 {
            let lineStart = text.lineRange(for: NSRange(location: start, length: 0)).location
            let prefix = text.substring(with: NSRange(location: lineStart, length: start - lineStart))
            if prefix.allSatisfy({ $0 == " " || $0 == "\t" }) { return nil }
        }
        let marker = String(repeating: typed, count: count)
        return replace(NSRange(location: start, length: count - 1), with: marker + marker, caret: start + count,
                       pair: AutoPair(opener: NSRange(location: start, length: count),
                                      closer: NSRange(location: start + count, length: count)))
    }
}
