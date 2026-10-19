//
//  Callout.swift
//  MarkdownEngine
//
//  Fork: Obsidian callouts inside a blockquote. A quote line whose
//  content is `[!type]`, optionally followed by `+` or `-` and a title, opens
//  a callout when it starts a deeper quote level (`> [!note]`, or
//  `> > [!quote]` under a `>` line). The callout runs over the following lines
//  at its level or deeper.
//

import Foundation

/// One line of a blockquote: its `>` markers and what follows them.
package struct QuoteLine: Equatable {
    /// The line, newline included.
    package let line: NSRange
    /// The line without its newline.
    package let text: NSRange
    /// The `>` run with its spaces.
    package let markers: NSRange
    /// After the markers, without the newline.
    package let content: NSRange
    /// The number of `>`.
    package let level: Int

    /// The lines of the blockquote at `range`.
    package static func lines(in range: NSRange, of ns: NSString) -> [QuoteLine] {
        var lines: [QuoteLine] = []
        var lineStart = range.location
        while lineStart < NSMaxRange(range) {
            let line = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            lines.append(parse(line, of: ns))
            lineStart = NSMaxRange(line)
        }
        return lines
    }

    /// Reads the markers of `line`, as `styleBlockquote` does: up to three spaces or tabs, then `>`s, each
    /// with an optional space or tab.
    package static func parse(_ line: NSRange, of ns: NSString) -> QuoteLine {
        let lineEnd = NSMaxRange(line)
        var i = line.location
        var indent = 0
        while i < lineEnd, indent < 3, ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09 {
            i += 1; indent += 1
        }
        let markerStart = i
        var level = 0
        var j = i
        while j < lineEnd, ns.character(at: j) == 0x3E /* > */ {
            level += 1; j += 1
            if j < lineEnd, ns.character(at: j) == 0x20 || ns.character(at: j) == 0x09 { j += 1 }
        }
        var textEnd = lineEnd
        while textEnd > line.location, ns.character(at: textEnd - 1) == 0x0A || ns.character(at: textEnd - 1) == 0x0D {
            textEnd -= 1
        }
        let contentStart = min(j, textEnd)
        return QuoteLine(line: line,
                         text: NSRange(location: line.location, length: textEnd - line.location),
                         markers: NSRange(location: markerStart, length: j - markerStart),
                         content: NSRange(location: contentStart, length: textEnd - contentStart),
                         level: level)
    }
}

/// A callout's title line: `[!type]`, a fold sign, the title.
package struct CalloutHeader: Equatable {
    /// Between `[!` and `]`.
    package let type: NSRange
    /// The `+` or `-` after `]`; empty, just after `]`, when there is none.
    package let fold: NSRange
    /// From `[` up to the title.
    package let syntax: NSRange
    /// Without trailing spaces; empty when the callout has no title.
    package let title: NSRange

    /// Reads a title line's `content` (after its `>` markers).
    package static func parse(_ ns: NSString, content: NSRange) -> CalloutHeader? {
        let end = NSMaxRange(content)
        var i = content.location
        guard end - i >= 4, ns.character(at: i) == 0x5B /* [ */, ns.character(at: i + 1) == 0x21 /* ! */ else { return nil }
        i += 2
        let typeStart = i
        while i < end, isTypeCharacter(ns.character(at: i)) { i += 1 }
        guard i > typeStart, i < end, ns.character(at: i) == 0x5D /* ] */ else { return nil }
        let type = NSRange(location: typeStart, length: i - typeStart)
        i += 1
        var fold = NSRange(location: i, length: 0)
        if i < end, ns.character(at: i) == 0x2B /* + */ || ns.character(at: i) == 0x2D /* - */ {
            fold.length = 1
            i += 1
        }
        guard i == end || ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09 else { return nil }
        while i < end, ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09 { i += 1 }
        var titleEnd = end
        while titleEnd > i, ns.character(at: titleEnd - 1) == 0x20 || ns.character(at: titleEnd - 1) == 0x09 { titleEnd -= 1 }
        return CalloutHeader(type: type, fold: fold,
                             syntax: NSRange(location: content.location, length: i - content.location),
                             title: NSRange(location: i, length: titleEnd - i))
    }

    /// Letters, digits, `-` and `_`.
    private static func isTypeCharacter(_ c: unichar) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2D || c == 0x5F
    }
}

/// A callout in a blockquote, by the indices of its lines.
package struct Callout: Equatable {
    package let level: Int
    package let header: CalloutHeader
    /// The title line.
    package let first: Int
    /// The last line at its level or deeper.
    package var last: Int

    package var hasBody: Bool { last > first }

    /// The callouts among a blockquote's `lines`, outer ones before the ones they hold.
    package static func find(in lines: [QuoteLine], of ns: NSString) -> [Callout] {
        var callouts: [Callout] = []
        var open: [Int] = []
        var previousLevel = 0
        for (index, line) in lines.enumerated() {
            while let top = open.last, callouts[top].level > line.level { open.removeLast() }
            for i in open { callouts[i].last = index }
            if line.level > previousLevel, let header = CalloutHeader.parse(ns, content: line.content) {
                callouts.append(Callout(level: line.level, header: header, first: index, last: index))
                open.append(callouts.count - 1)
            }
            previousLevel = line.level
        }
        return callouts
    }
}
