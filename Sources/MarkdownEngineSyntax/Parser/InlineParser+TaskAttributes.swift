//
//  InlineParser+TaskAttributes.swift
//  MarkdownEngineSyntax
//
//  Fork: a task line's attributes. `>YYYY-MM-DD` after whitespace is a due date; `@` straight before a wiki link
//  (`@[[Title]]`), after whitespace, is a parent. Read from a task item's first line when the registry asks for them.
//

import Foundation

/// Fork: which attribute a `.taskAttribute` node is.
public enum TaskAttributeKind: Sendable, Equatable {
    /// `>YYYY-MM-DD`.
    case due
    /// `@[[Title]]`.
    case parent
}

public enum TaskAttributeSyntax {
    /// Whether `text` is a calendar date written `YYYY-MM-DD`.
    public static func isDate(_ text: some StringProtocol) -> Bool {
        let u = Array(text.utf8)
        guard u.count == 10, u[4] == 0x2D, u[7] == 0x2D else { return false }
        func digits(_ range: Range<Int>) -> Int? {
            var value = 0
            for i in range {
                guard u[i] >= 0x30, u[i] <= 0x39 else { return nil }
                value = value * 10 + Int(u[i] - 0x30)
            }
            return value
        }
        guard let year = digits(0..<4), let month = digits(5..<7), let day = digits(8..<10),
              (1...12).contains(month), day >= 1 else { return false }
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return day <= lengths[month - 1]
    }

    /// Whether the line prefix (the line's text before a position) is a task item's up to and including the box and
    /// the space after it: indent, a list marker (`-`, `*`, `+`, `1.`, `1)`), one to four spaces, `[c]`, then a
    /// space or tab. Text after the box may follow.
    package static func isTaskLinePrefix(_ prefix: NSString) -> Bool {
        let end = prefix.length
        var i = 0
        while i < end, prefix.character(at: i) == 0x20 || prefix.character(at: i) == 0x09 { i += 1 }
        guard i < end else { return false }
        let c = prefix.character(at: i)
        if c == 0x2D || c == 0x2A || c == 0x2B {
            i += 1
        } else {
            var digits = 0
            while i < end, prefix.character(at: i) >= 0x30, prefix.character(at: i) <= 0x39, digits < 9 { i += 1; digits += 1 }
            guard digits > 0, i < end, prefix.character(at: i) == 0x2E || prefix.character(at: i) == 0x29 else { return false }
            i += 1
        }
        return TaskMarker.boxStart(in: { prefix.character(at: $0) }, markerEnd: i, end: end) != nil
    }
}

extension InlineParser {
    /// A task item's inline nodes with its attributes read: a `.text` node holding `>YYYY-MM-DD` (after whitespace,
    /// then the text's end or a character that isn't a letter, digit, `-` or `_`) splits around a `.due`, and one
    /// ending in `@` after whitespace, followed at once by a `.wikiLink`, gives a `.parent` over both. Top-level nodes
    /// only: code, links, emphasis and the rest hold none.
    static func readingTaskAttributes(_ nodes: [InlineNode], in ns: NSString) -> [InlineNode] {
        func isSpace(at index: Int) -> Bool {
            index < 0 || Unicode.Scalar(ns.character(at: index)).map { CharacterSet.whitespaces.contains($0) } ?? false
        }
        var result: [InlineNode] = []
        var index = 0
        while index < nodes.count {
            defer { index += 1 }
            guard case .text(let range) = nodes[index] else { result.append(nodes[index]); continue }
            var from = range.location
            var cursor = range.location
            let end = NSMaxRange(range)
            func flush(upTo stop: Int) {
                if stop > from { result.append(.text(NSRange(location: from, length: stop - from))) }
            }
            while cursor < end {
                defer { cursor += 1 }
                let c = ns.character(at: cursor)
                guard c == 0x3E || c == 0x40, isSpace(at: cursor - 1) else { continue }
                if c == 0x3E {
                    guard cursor + 11 <= end, isDate(ns.substring(with: NSRange(location: cursor + 1, length: 10))) else { continue }
                    if cursor + 11 < end {
                        let next = ns.character(at: cursor + 11)
                        if let scalar = Unicode.Scalar(next), CharacterSet.alphanumerics.contains(scalar) || next == 0x2D || next == 0x5F {
                            continue
                        }
                    }
                    flush(upTo: cursor)
                    let marker = NSRange(location: cursor, length: 1)
                    result.append(.taskAttribute(.due, range: NSRange(location: cursor, length: 11), marker: marker,
                                                 content: NSRange(location: cursor + 1, length: 10), markers: [marker]))
                    cursor += 10
                    from = cursor + 1
                } else if cursor == end - 1, index + 1 < nodes.count,
                          case .wikiLink(let link, let name, _, let markers) = nodes[index + 1], link.location == end,
                          name.length > 0 {
                    flush(upTo: cursor)
                    let marker = NSRange(location: cursor, length: 1)
                    result.append(.taskAttribute(.parent, range: NSRange(location: cursor, length: NSMaxRange(link) - cursor),
                                                 marker: marker, content: name, markers: [marker] + markers))
                    from = end
                    index += 1   // the link is the attribute's
                }
            }
            flush(upTo: end)
        }
        return result
    }

    private static func isDate(_ text: String) -> Bool { TaskAttributeSyntax.isDate(text) }
}
