//
//  InlineParser+TaskAttributes.swift
//  MarkdownEngineSyntax
//
//  Fork: a task line's attributes. `>YYYY-MM-DD` after a space, a tab or the text's start is a due date; `@` straight
//  before `[[Title]]`, likewise placed, is a parent. The first of each counts; code spans and links hold none. The
//  scan is the host's rule (`docs/file-format.md` ▸ Subtask attributes): emphasis, `~~`, `==` and math are read through.
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
    /// Whether `text` is a calendar date written `YYYY-MM-DD`, year 0001 to 9999.
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
              (1...9999).contains(year), (1...12).contains(month), day >= 1 else { return false }
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

    /// Whether `line`, a line's text up to the caret or the whole line, is a task item's up to and including its box
    /// and the space or tab after it. It is the rule the `.date` and `.parent` queries use.
    public static func isTaskAttributeLine(_ line: String) -> Bool { isTaskLinePrefix(line as NSString) }

    /// The title of the file a link's inner text (`target#heading|alias`) names: its target's last path component
    /// without `.md`. Nil when it links no file (`[[#heading]]`).
    public static func parentTitle(inner: String) -> String? {
        guard let parts = WikiLinkParts(inner: inner), !parts.target.isEmpty else { return nil }
        let name = parts.target.split(separator: "/").last.map(String.init) ?? parts.target
        return name.lowercased().hasSuffix(".md") ? String(name.dropLast(3)) : name
    }

    /// A due date or parent found by ``scan(_:in:)``.
    package struct Found: Equatable {
        package var kind: TaskAttributeKind
        /// `>YYYY-MM-DD`, or `@[[…]]`.
        package var range: NSRange
        /// The date, or the parent's bare title.
        package var value: String
    }

    private static let (backslash, paren, closeParen): (UInt16, UInt16, UInt16) = (0x5C, 0x28, 0x29)

    /// The index after the code span opened by the backtick run at `i`, or after the run when nothing closes it.
    private static func afterCodeSpan(_ u: [UInt16], at i: Int) -> Int {
        var length = 0
        while i + length < u.count, u[i + length] == 0x60 { length += 1 }
        var j = i + length
        while j < u.count {
            guard u[j] == 0x60 else { j += 1; continue }
            var run = 0
            while j + run < u.count, u[j + run] == 0x60 { run += 1 }
            if run == length { return j + run }
            j += run
        }
        return i + length
    }

    /// The index after the `[[…]]`, `[text](target)` or `[text][ref]` that starts at `i`, or after the bracket when it
    /// isn't one. The text's brackets nest, a backslash escapes, and the target's parentheses balance.
    private static func afterLink(_ u: [UInt16], at i: Int) -> Int {
        if i + 1 < u.count, u[i + 1] == 0x5B {
            var j = i + 2
            while j + 1 < u.count {
                if u[j] == 0x5D, u[j + 1] == 0x5D { return j + 2 }
                j += 1
            }
            return i + 1
        }
        guard let end = closingBracket(u, from: i), end + 1 < u.count else { return i + 1 }
        if u[end + 1] == 0x5B {
            return u[(end + 2)...].firstIndex(of: 0x5D).map { $0 + 1 } ?? i + 1
        }
        guard u[end + 1] == paren else { return i + 1 }
        var depth = 0, j = end + 1
        while j < u.count {
            switch u[j] {
            case backslash: j += 1
            case paren: depth += 1
            case closeParen:
                depth -= 1
                if depth == 0 { return j + 1 }
            default: break
            }
            j += 1
        }
        return i + 1
    }

    /// The `]` that closes the `[` at `i`, skipping nested brackets, escapes and code spans.
    private static func closingBracket(_ u: [UInt16], from i: Int) -> Int? {
        var depth = 0, j = i
        while j < u.count {
            switch u[j] {
            case backslash: j += 1
            case 0x60: j = afterCodeSpan(u, at: j) - 1
            case 0x5B: depth += 1
            case 0x5D:
                depth -= 1
                if depth == 0 { return j }
            default: break
            }
            j += 1
        }
        return nil
    }

    /// The attributes in `range`, a task line's text after its box (UTF-16 in `ns`): the first due date and the first
    /// parent, in text order. Each starts the text or follows a space or tab; code spans and links hold none.
    package static func scan(_ ns: NSString, in range: NSRange) -> [Found] {
        let u = Array(ns.substring(with: range).utf16)
        let (space, tab, backtick, greater, at, open, close, newline): (UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16)
            = (0x20, 0x09, 0x60, 0x3E, 0x40, 0x5B, 0x5D, 0x0A)
        guard u.contains(greater) || u.contains(at) else { return [] }
        var due: Found?
        var parent: Found?
        var i = 0
        while i < u.count, due == nil || parent == nil {
            let atBoundary = i == 0 || u[i - 1] == space || u[i - 1] == tab
            switch u[i] {
            case backtick:
                i = afterCodeSpan(u, at: i)
            case open:
                i = afterLink(u, at: i)
            case greater where atBoundary && due == nil:
                if i + 11 <= u.count {
                    let text = String(decoding: u[(i + 1)..<(i + 11)], as: UTF16.self)
                    var runsOn = false
                    if i + 11 < u.count, let scalar = Unicode.Scalar(u[i + 11]), CharacterSet.alphanumerics.contains(scalar) {
                        runsOn = true
                    }
                    if !runsOn, isDate(text) {
                        due = Found(kind: .due, range: NSRange(location: range.location + i, length: 11), value: text)
                    }
                }
                i += 1
            case at where atBoundary && parent == nil && i + 2 < u.count && u[i + 1] == open && u[i + 2] == open:
                var j = i + 3
                while j + 1 < u.count, u[j] != close, u[j] != open, u[j] != newline { j += 1 }
                if j + 1 < u.count, u[j] == close, u[j + 1] == close,
                   let title = parentTitle(inner: String(decoding: u[(i + 3)..<j], as: UTF16.self)) {
                    parent = Found(kind: .parent, range: NSRange(location: range.location + i, length: j + 2 - i), value: title)
                    i = j + 2
                } else {
                    i += 1
                }
            default:
                i += 1
            }
        }
        return [due, parent].compactMap { $0 }.sorted { $0.range.location < $1.range.location }
    }
}

extension InlineParser {
    /// A task item's inline nodes with its attributes (`found`, from `TaskAttributeSyntax.scan`) as nodes where the
    /// tree allows: a `.due` carved out of a text node, a `.parent` replacing a text node's closing `@` and the wiki
    /// link right after it. Emphasis and extension spans (`~~`, `==`) are entered; an attribute the tree holds
    /// otherwise (in math, or a link the parser reads differently) stays as the nodes read it.
    static func readingTaskAttributes(_ nodes: [InlineNode], found: [TaskAttributeSyntax.Found]) -> [InlineNode] {
        var pending = found
        return carve(nodes, pending: &pending)
    }

    private static func carve(_ nodes: [InlineNode], pending: inout [TaskAttributeSyntax.Found]) -> [InlineNode] {
        var result: [InlineNode] = []
        var index = 0
        while index < nodes.count {
            defer { index += 1 }
            switch nodes[index] {
            case .text(let range):
                var from = range.location
                for attribute in pending where attribute.kind == .due
                    && attribute.range.location >= from && NSMaxRange(attribute.range) <= NSMaxRange(range) {
                    if attribute.range.location > from {
                        result.append(.text(NSRange(location: from, length: attribute.range.location - from)))
                    }
                    let marker = NSRange(location: attribute.range.location, length: 1)
                    result.append(.taskAttribute(.due, range: attribute.range, marker: marker,
                                                 content: NSRange(location: marker.location + 1, length: 10), markers: [marker]))
                    from = NSMaxRange(attribute.range)
                    pending.removeAll { $0 == attribute }
                }
                if let parent = pending.first(where: { $0.kind == .parent }), index + 1 < nodes.count,
                   NSMaxRange(range) == parent.range.location + 1, from <= parent.range.location,
                   case .wikiLink(let link, let name, _, let markers) = nodes[index + 1],
                   link.location == parent.range.location + 1, NSMaxRange(link) == NSMaxRange(parent.range), name.length > 0 {
                    if parent.range.location > from {
                        result.append(.text(NSRange(location: from, length: parent.range.location - from)))
                    }
                    let marker = NSRange(location: parent.range.location, length: 1)
                    result.append(.taskAttribute(.parent, range: parent.range, marker: marker, content: name,
                                                 markers: [marker] + markers))
                    from = NSMaxRange(range)
                    pending.removeAll { $0 == parent }
                    index += 1   // the link is the attribute's
                }
                if NSMaxRange(range) > from { result.append(.text(NSRange(location: from, length: NSMaxRange(range) - from))) }
            case .emphasis(let kind, let range, let markers, let children):
                result.append(.emphasis(kind, range: range, markers: markers, children: carve(children, pending: &pending)))
            case .ext(let node):
                result.append(.ext(ExtensionInlineNode(
                    extensionID: node.extensionID, range: node.range, contentRange: node.contentRange,
                    markers: node.markers, children: carve(node.children, pending: &pending))))
            default:
                result.append(nodes[index])
            }
        }
        return result
    }
}
