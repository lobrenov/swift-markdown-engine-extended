//
//  TagEdit.swift
//  MarkdownEngineSyntax
//
//  Fork: whole-text edits of the inline `#tags` the parser reads, changing only the tags' own bytes.
//

import Foundation

public enum TagEdit {
    /// `text` with every inline tag whose path is `from` or under it (ignoring case) renamed: that prefix of the
    /// path becomes `to`, the rest keeps its spelling. Paths compare by their non-empty segments (`a//b` is `a/b`), and
    /// a renamed tag is written with its empty segments dropped. `from` and `to` are paths without `#`. Text the
    /// parser reads no tag in is untouched, and `text` is returned as it was when nothing matches.
    public static func rename(_ from: String, to: String, in text: String) -> String {
        let ns = text as NSString
        var edits: [(range: NSRange, replacement: String)] = []
        for tag in matches(of: from, in: text) {
            let name = NSRange(location: tag.range.location + 1, length: tag.range.length - 1)
            let replacement = ([to] + tag.rest).joined(separator: "/")
            if ns.substring(with: name) != replacement { edits.append((name, replacement)) }
        }
        return apply(edits, to: text)
    }

    /// `text` with every inline tag whose path is `from` or under it (ignoring case) removed with its `#`, its
    /// trailing `/`s and one adjacent whitespace character: the one before the tag, else the one after it. A line
    /// break is never removed, so a line left empty stays as a line. A `*` or `_` emphasis span left holding only
    /// whitespace is removed with its markers, and the whitespace rule applies to the span.
    public static func delete(_ from: String, in text: String) -> String {
        let ns = text as NSString
        func isBlank(_ unit: Int) -> Bool {
            let composed = ns.rangeOfComposedCharacterSequence(at: unit)
            let c = Character(ns.substring(with: composed))
            return c.isWhitespace && !c.isNewline
        }
        let found = matches(of: from, in: text)
        let removed = found.map { tag -> NSRange in
            var end = NSMaxRange(tag.range)
            while end < ns.length, ns.character(at: end) == 0x2F { end += 1 }
            return NSRange(location: tag.range.location, length: end - tag.range.location)
        }
        /// Whether `range` holds only whitespace once the tags being removed are set aside.
        func isEmpty(_ range: NSRange) -> Bool {
            (range.location..<NSMaxRange(range)).allSatisfy { unit in
                removed.contains { NSLocationInRange(unit, $0) }
                    || Character(ns.substring(with: NSRange(location: unit, length: 1))).isWhitespace
            }
        }
        var ranges: [NSRange] = []
        for (tag, tagRange) in zip(found, removed) {
            var range = tagRange
            for wrapper in tag.wrappers {
                let start = tag.range.location - wrapper.before
                let end = NSMaxRange(tag.range) + wrapper.after
                let contentStart = start + wrapper.open
                let contentEnd = end - wrapper.close
                guard contentStart <= contentEnd, contentEnd <= ns.length,
                      isEmpty(NSRange(location: contentStart, length: contentEnd - contentStart)) else { break }
                range = NSRange(location: start, length: end - start)
            }
            let end = NSMaxRange(range)
            if range.location > 0, isBlank(range.location - 1) {
                let before = ns.rangeOfComposedCharacterSequence(at: range.location - 1)
                range = NSRange(location: before.location, length: end - before.location)
            } else if end < ns.length, isBlank(end) {
                range.length = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: end)) - range.location
            }
            ranges.append(range)
        }
        ranges.sort { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in ranges {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1].length = max(NSMaxRange(last), NSMaxRange(range)) - last.location
            } else {
                merged.append(range)
            }
        }
        return apply(merged.map { ($0, "") }, to: text)
    }

    /// The tags at `from` or under it: where each is in `text` (`#` through its last character), the path segments
    /// after the ones `from` names (as written), and the emphasis spans around it.
    private static func matches(of from: String, in text: String)
        -> [(range: NSRange, rest: [String], wrappers: [MarkdownFacts.Tag.Wrapper])] {
        let wanted = from.split(separator: "/").map(String.init)
        guard !wanted.isEmpty else { return [] }
        let ns = text as NSString
        var lineStarts = [0]
        var cursor = 0
        while cursor < ns.length {
            cursor = NSMaxRange(ns.lineRange(for: NSRange(location: cursor, length: 0)))
            if cursor < ns.length { lineStarts.append(cursor) }
        }
        var found: [(range: NSRange, rest: [String], wrappers: [MarkdownFacts.Tag.Wrapper])] = []
        for tag in MarkdownFacts.scan(text).tags {
            let range = NSRange(location: lineStarts[tag.line] + tag.column, length: tag.length)
            guard NSMaxRange(range) <= ns.length else { continue }
            let path = ns.substring(with: NSRange(location: range.location + 1, length: range.length - 1))
            let segments = path.split(separator: "/").map(String.init)
            guard ns.character(at: range.location) == 0x23, path == tag.name, segments.count >= wanted.count,
                  zip(segments, wanted).allSatisfy({ $0.compare($1, options: .caseInsensitive) == .orderedSame })
            else { continue }
            found.append((range, Array(segments.dropFirst(wanted.count)), tag.wrappers))
        }
        return found
    }

    /// `edits` (in text order, not overlapping) applied to `text`.
    private static func apply(_ edits: [(range: NSRange, replacement: String)], to text: String) -> String {
        guard !edits.isEmpty else { return text }
        let out = NSMutableString(string: text)
        for edit in edits.reversed() { out.replaceCharacters(in: edit.range, with: edit.replacement) }
        return out as String
    }
}
