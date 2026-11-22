//
//  TagEdit.swift
//  MarkdownEngineSyntax
//
//  Fork: whole-text edits of the inline `#tags` the parser reads, changing only the tags' own bytes.
//

import Foundation

public enum TagEdit {
    /// `text` with every inline tag whose path is `from` or under it (ignoring case) renamed: that prefix of the
    /// path becomes `to`, the rest keeps its spelling. `from` and `to` are paths without `#`. Text the parser reads no
    /// tag in is untouched, and `text` is returned as it was when nothing matches.
    public static func rename(_ from: String, to: String, in text: String) -> String {
        let ns = text as NSString
        var edits: [(range: NSRange, replacement: String)] = []
        for tag in matches(of: from, in: text) {
            let prefix = ns.substring(with: NSRange(location: tag.range.location + 1, length: tag.prefixLength))
            if prefix != to { edits.append((NSRange(location: tag.range.location + 1, length: tag.prefixLength), to)) }
        }
        return apply(edits, to: text)
    }

    /// `text` with every inline tag whose path is `from` or under it (ignoring case) removed with its `#` and one
    /// adjacent whitespace character: the one before the tag, else the one after it. A line break is never removed,
    /// so a line left empty stays as a line.
    public static func delete(_ from: String, in text: String) -> String {
        let ns = text as NSString
        func isBlank(_ unit: Int) -> Bool {
            let composed = ns.rangeOfComposedCharacterSequence(at: unit)
            let c = Character(ns.substring(with: composed))
            return c.isWhitespace && !c.isNewline
        }
        var ranges: [NSRange] = []
        for tag in matches(of: from, in: text) {
            var range = tag.range
            let end = NSMaxRange(range)
            if range.location > 0, isBlank(range.location - 1) {
                let before = ns.rangeOfComposedCharacterSequence(at: range.location - 1)
                range = NSRange(location: before.location, length: NSMaxRange(range) - before.location)
            } else if end < ns.length, isBlank(end) {
                range.length = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: end)) - range.location
            }
            ranges.append(range)
        }
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

    /// The tags at `from` or under it: where each is in `text` (`#` through its last character) and the UTF-16 length of
    /// its path's prefix that `from` names.
    private static func matches(of from: String, in text: String) -> [(range: NSRange, prefixLength: Int)] {
        guard !from.isEmpty else { return [] }
        let ns = text as NSString
        var lineStarts = [0]
        var cursor = 0
        while cursor < ns.length {
            cursor = NSMaxRange(ns.lineRange(for: NSRange(location: cursor, length: 0)))
            if cursor < ns.length { lineStarts.append(cursor) }
        }
        var found: [(range: NSRange, prefixLength: Int)] = []
        for tag in MarkdownFacts.scan(text).tags {
            let range = NSRange(location: lineStarts[tag.line] + tag.column, length: tag.length)
            guard NSMaxRange(range) <= ns.length else { continue }
            let path = ns.substring(with: NSRange(location: range.location + 1, length: range.length - 1)) as NSString
            let prefix = path.range(of: from, options: [.caseInsensitive, .anchored])
            guard ns.character(at: range.location) == 0x23, path as String == tag.name, prefix.location == 0,
                  prefix.length == path.length || path.character(at: prefix.length) == 0x2F else { continue }
            found.append((range, prefix.length))
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
