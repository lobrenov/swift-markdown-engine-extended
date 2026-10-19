//
//  MarkdownListIndent.swift
//  MarkdownEngine
//
//  Fork: Tab / Shift-Tab over list items.
//  - Acts on every list line the selection touches, plus each one's children
//    (deeper lines directly below), so a subtree moves together.
//  - Tab only nests an item under a previous sibling. A first item has none:
//    indenting it would leave it nested under nothing, which CommonMark reads
//    as an indented code block.
//  - Edits only insert or delete leading whitespace, one line at a time, in one
//    undo group. Never rewrite a span: that drops `.wikiLinkID` (see ContextMenu.swift).
//  - In a quote, the item's whitespace is the whitespace after its `>` markers, and
//    siblings and children are lines at the same quote level.
//

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import MarkdownEngineSyntax

extension MarkdownLists {

    /// Tab over list lines. Nil when the selection touches no list line (Tab behaves normally).
    static func indentListLines(_ textView: PlatformTextView, selection: NSRange, maximumLevel: Int) -> Bool? {
        let ns = textView.string as NSString
        let lines = targetLines(in: ns, selection: selection)
        guard let first = lines.first else { return nil }
        guard hasPreviousSibling(of: first, in: ns),
              lines.allSatisfy({ level(ofLineAt: $0, in: ns) < maximumLevel }) else { return true }
        applyLineEdits(textView, selection: selection,
                       edits: lines.map { (location: $0.location + quotePrefix(ofLineAt: $0, in: ns), delete: 0, insert: "\t") })
        return true
    }

    /// Shift-Tab over list lines. Nil when the selection touches no list line.
    static func outdentListLines(_ textView: PlatformTextView, selection: NSRange) -> Bool? {
        let ns = textView.string as NSString
        let lines = targetLines(in: ns, selection: selection)
        guard !lines.isEmpty else { return nil }
        let edits = lines.compactMap { line -> (location: Int, delete: Int, insert: String)? in
            let ws = leadingWhitespace(ofLineAt: line, in: ns)
            let location = line.location + quotePrefix(ofLineAt: line, in: ns)
            if ws.hasPrefix("\t") { return (location, 1, "") }
            let spaces = ws.prefix(2).prefix { $0 == " " }.count
            return spaces > 0 ? (location, spaces, "") : nil
        }
        applyLineEdits(textView, selection: selection, edits: edits)
        return true
    }

    // MARK: Lines

    /// List lines touched by the selection, each followed by its deeper children.
    static func targetLines(in ns: NSString, selection: NSRange) -> [NSRange] {
        // A selection ending exactly at a line start doesn't touch that line.
        let start = min(selection.location, ns.length)
        var end = min(NSMaxRange(selection), ns.length)
        if selection.length > 0, end > start, end > 0, ns.character(at: end - 1) == 0x0A { end -= 1 }
        let block = ns.lineRange(for: NSRange(location: start, length: end - start))
        var result: [NSRange] = []
        var location = block.location
        repeat {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            if isListLine(line, in: ns) { result.append(line) }
            location = NSMaxRange(line)
        } while location < NSMaxRange(block)
        guard let last = result.last else { return [] }
        // Children of the last touched item: deeper list lines (blank lines between are allowed).
        let parentLevel = level(ofLineAt: last, in: ns)
        let quote = quoteLevel(ofLineAt: last, in: ns)
        location = NSMaxRange(last)
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            if isBlank(line, in: ns) { location = NSMaxRange(line); continue }
            guard isListLine(line, in: ns), quoteLevel(ofLineAt: line, in: ns) == quote,
                  level(ofLineAt: line, in: ns) > parentLevel else { break }
            result.append(line)
            location = NSMaxRange(line)
        }
        return result
    }

    /// Walking up past blank lines and deeper items, is the first list line at the same level?
    static func hasPreviousSibling(of line: NSRange, in ns: NSString) -> Bool {
        let itemLevel = level(ofLineAt: line, in: ns)
        let quote = quoteLevel(ofLineAt: line, in: ns)
        var location = line.location
        while location > 0 {
            let previous = ns.lineRange(for: NSRange(location: location - 1, length: 0))
            location = previous.location
            if isBlank(previous, in: ns) { continue }
            guard isListLine(previous, in: ns), quoteLevel(ofLineAt: previous, in: ns) == quote else { return false }
            let previousLevel = level(ofLineAt: previous, in: ns)
            if previousLevel > itemLevel { continue }
            return previousLevel == itemLevel
        }
        return false
    }

    static func isListLine(_ line: NSRange, in ns: NSString) -> Bool {
        let text = ns.substring(with: afterQuote(line, in: ns))
        return listRegex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    static func isBlank(_ line: NSRange, in ns: NSString) -> Bool {
        ns.substring(with: afterQuote(line, in: ns)).allSatisfy(\.isWhitespace)
    }

    static func leadingWhitespace(ofLineAt line: NSRange, in ns: NSString) -> String {
        String(ns.substring(with: afterQuote(line, in: ns)).prefix { $0 == " " || $0 == "\t" })
    }

    /// The length of a quote line's `>` markers and the space after each; 0 off a quote.
    static func quotePrefix(ofLineAt line: NSRange, in ns: NSString) -> Int {
        let quote = QuoteLine.parse(line, of: ns)
        return quote.level > 0 ? NSMaxRange(quote.markers) - line.location : 0
    }

    static func quoteLevel(ofLineAt line: NSRange, in ns: NSString) -> Int {
        QuoteLine.parse(line, of: ns).level
    }

    private static func afterQuote(_ line: NSRange, in ns: NSString) -> NSRange {
        let prefix = quotePrefix(ofLineAt: line, in: ns)
        return NSRange(location: line.location + prefix, length: line.length - prefix)
    }

    static func level(ofLineAt line: NSRange, in ns: NSString) -> Int {
        indentLevel(from: leadingWhitespace(ofLineAt: line, in: ns))
    }

    // MARK: Editing

    /// Applies whitespace edits bottom-up (so earlier offsets stay valid) in one undo group,
    /// then shifts the selection to follow the text.
    private static func applyLineEdits(_ textView: PlatformTextView, selection: NSRange,
                                       edits: [(location: Int, delete: Int, insert: String)]) {
        guard !edits.isEmpty else { return }
        textView.undoManager?.beginUndoGrouping()
        for edit in edits.sorted(by: { $0.location > $1.location }) {
            performEdit(textView, replace: NSRange(location: edit.location, length: edit.delete), with: edit.insert)
        }
        textView.undoManager?.endUndoGrouping()

        func shifted(_ position: Int, includingEditsAt: Bool) -> Int {
            var result = position
            for edit in edits where edit.location < position || (includingEditsAt && edit.location == position) {
                result += (edit.insert as NSString).length - min(edit.delete, position - edit.location)
            }
            return result
        }
        let start = shifted(selection.location, includingEditsAt: true)
        let end = selection.length == 0 ? start : shifted(NSMaxRange(selection), includingEditsAt: false)
        let length = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: min(start, length), length: max(0, min(end, length) - min(start, length))))
    }
}
