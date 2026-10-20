//
//  MarkdownAST.swift
//  MarkdownEngine
//
//  Phase 2.5 foundation: the semantic document AST. Combines the block-structure
//  pass (BlockParser) with the inline pass (InlineParser) into one tree of
//  `BlockNode`s, each inline-bearing block carrying its parsed inline children
//  in absolute document coordinates. The AST-native styler (next increments)
//  walks this tree instead of consuming flat tokens.
//

import Foundation

/// One list-item line: marker run, optional GFM checkbox, and indent column count.
package struct ListItem: Equatable {
    package let range: NSRange          // the item's full line (incl. trailing newline)
    package let marker: NSRange
    package let ordered: Bool
    package let number: Int?            // ordered start value, e.g. `5.` → 5
    package let checkbox: NSRange?
    package let checked: Bool
    /// Fork: the character between the brackets (see `TaskMarker`), nil without a checkbox.
    package let taskMarker: Character?
    package let indent: Int
    package let contentRange: NSRange   // text after the marker (and checkbox)
    package let inlines: [InlineNode]
}

/// An extension-supplied fenced block. `closeFence` is nil when the block is
/// unclosed (it then runs to the end of the document).
package struct ExtensionBlockNode: Equatable {
    package let extensionID: String
    package let range: NSRange
    package let openFence: NSRange      // opening fence line incl. its newline
    package let closeFence: NSRange?    // closing fence line, nil when unclosed
    package let contentRange: NSRange   // lines between the fences
    package let inlines: [InlineNode]
}

/// A top-level block in the document AST.
package indirect enum BlockNode: Equatable {
    case paragraph(range: NSRange, inlines: [InlineNode])
    case heading(level: Int, range: NSRange, markers: [NSRange], inlines: [InlineNode])
    /// Fork: `items` are the list items on the quote's lines (`> - [ ] a`), read after the `>` markers.
    case blockquote(range: NSRange, inlines: [InlineNode], items: [ListItem])
    case list(range: NSRange, items: [ListItem])
    case codeBlock(range: NSRange)
    /// Fork: lines indented 4+ columns, shown as code without fences.
    case indentedCode(range: NSRange)
    /// Fork: a CommonMark HTML block, kept as source.
    case html(range: NSRange)
    case blockLatex(range: NSRange)
    case table(range: NSRange)
    case thematicBreak(range: NSRange)
    case blank(range: NSRange)
    case ext(ExtensionBlockNode)

    package var range: NSRange {
        switch self {
        case .paragraph(let r, _), .heading(_, let r, _, _), .blockquote(let r, _, _),
             .list(let r, _), .codeBlock(let r), .indentedCode(let r), .html(let r), .blockLatex(let r), .table(let r),
             .thematicBreak(let r), .blank(let r):
            return r
        case .ext(let node):
            return node.range
        }
    }
}

package enum DocumentAST {

    private static let hash: unichar = 0x23
    private static let space: unichar = 0x20
    private static let tab: unichar = 0x09

    /// Build the document AST; `scopedRanges` parses inlines only for intersecting blocks.
    /// `precomputedBlocks` (the keystroke's own parse state, handed down by the
    /// restyle) skips BlockParser.parse — whose cache "hit" still re-extracts
    /// and memcmps the full document buffer — entirely.
    package static func parse(_ text: String, scopedRanges: [NSRange]? = nil, precomputedBlocks: [Block]? = nil,
                      registry: ExtensionRegistry = .empty) -> [BlockNode] {
        let ns = text as NSString
        let blocks = precomputedBlocks ?? BlockParser.parse(text, registry: registry)
        let normalizedScopes = scopedRanges.map {
            normalizeScopes($0, documentLength: ns.length)
        }
        // Scoped mode: skip building BlockNodes for blocks outside the edit.
        // Blocks tile the document in order, so one sweep over sorted candidate
        // ranges replaces scanning every candidate per block (which went
        // quadratic in formula-rich documents with dozens of candidates).
        let relevant: [(block: Block, scopes: [NSRange]?)]
        if let normalizedScopes {
            var out: [(Block, [NSRange]?)] = []
            var ci = 0
            for block in blocks {
                while ci < normalizedScopes.count,
                      NSMaxRange(normalizedScopes[ci]) <= block.range.location {
                    ci += 1
                }
                guard ci < normalizedScopes.count else { break }
                var intersections: [NSRange] = []
                var si = ci
                while si < normalizedScopes.count,
                      normalizedScopes[si].location < NSMaxRange(block.range) {
                    intersections.append(normalizedScopes[si])
                    si += 1
                }
                if !intersections.isEmpty {
                    out.append((block, intersections))
                }
            }
            relevant = out
        } else {
            relevant = blocks.map { ($0, nil) }
        }
        return relevant.map { candidate in
            node(
                for: candidate.block,
                ns: ns,
                scopedRanges: candidate.scopes,
                registry: registry
            )
        }
    }

    /// Reject malformed UTF-16 ranges, then merge them once so every scoped
    /// consumer can use the same monotonic view of the edit region.
    private static func normalizeScopes(
        _ ranges: [NSRange],
        documentLength: Int
    ) -> [NSRange] {
        let sorted = ranges.compactMap { range -> NSRange? in
            guard range.location != NSNotFound,
                  range.location >= 0,
                  range.length > 0 else { return nil }
            let (end, overflowed) = range.location.addingReportingOverflow(
                range.length
            )
            guard !overflowed, end <= documentLength else { return nil }
            return range
        }
        .sorted {
            $0.location == $1.location
                ? $0.length < $1.length
                : $0.location < $1.location
        }

        var result: [NSRange] = []
        result.reserveCapacity(sorted.count)
        for range in sorted {
            guard let previous = result.last else {
                result.append(range)
                continue
            }
            let previousEnd = NSMaxRange(previous)
            guard range.location <= previousEnd else {
                result.append(range)
                continue
            }
            let end = max(previousEnd, NSMaxRange(range))
            result[result.count - 1].length = end - previous.location
        }
        return result
    }

    private static func inScope(_ range: NSRange, _ scopedRanges: [NSRange]?) -> Bool {
        guard let scopedRanges else { return true }
        return scopedRanges.contains { NSIntersectionRange($0, range).length > 0 }
    }

    private static func node(for block: Block, ns: NSString, scopedRanges: [NSRange]?, registry: ExtensionRegistry) -> BlockNode {
        let scoped = inScope(block.range, scopedRanges)
        switch block.kind {
        case .paragraph:
            return .paragraph(range: block.range, inlines: scoped ? InlineParser.parse(ns, range: block.range, registry: registry) : [])
        case .heading:
            return heading(block.range, ns, scoped: scoped, registry: registry)
        case .blockquote:
            return .blockquote(range: block.range, inlines: scoped ? InlineParser.parse(ns, range: block.range, registry: registry) : [],
                               items: quotedListItems(block.range, ns))
        case .list:
            return list(
                block.range,
                ns,
                scopedRanges: scopedRanges,
                registry: registry
            )
        case .fencedCode:
            return .codeBlock(range: block.range)
        case .indentedCode:
            return .indentedCode(range: block.range)
        case .html:
            return .html(range: block.range)
        case .blockLatex:
            return .blockLatex(range: block.range)
        case .table:
            return .table(range: block.range)
        case .thematicBreak:
            return .thematicBreak(range: block.range)
        case .blank:
            return .blank(range: block.range)
        case .ext(let id):
            return extensionBlock(id: id, range: block.range, ns, scoped: scoped, registry: registry)
        }
    }

    /// Split an extension fenced block into open fence line, optional closing
    /// fence line, and the content between; inlines parse over the content.
    private static func extensionBlock(id: String, range: NSRange, _ ns: NSString,
                                       scoped: Bool, registry: ExtensionRegistry) -> BlockNode {
        let fence = registry.blockEntry(for: id)?.fence ?? ""
        let end = NSMaxRange(range)
        // Opening fence line including its terminator — via lineRange, the
        // same primitive the block parser tiles with, so the fence/content
        // split agrees on EVERY line terminator (\n, \r\n, U+2028, …).
        let openLine = ns.lineRange(for: NSRange(location: range.location, length: 0))
        let openEnd = min(NSMaxRange(openLine), end)
        let openFence = NSRange(location: range.location, length: openEnd - range.location)

        // Closing fence: the block's last line, when it starts with the fence
        // and is not the opening line itself.
        var closeFence: NSRange?
        if openEnd < end {
            let lastLine = ns.lineRange(for: NSRange(location: end - 1, length: 0))
            if lastLine.location >= openEnd,
               !fence.isEmpty,
               ns.substring(with: lastLine).hasPrefix(fence) {
                closeFence = lastLine
            }
        }

        let contentEnd = closeFence?.location ?? end
        let contentRange = NSRange(location: openEnd, length: max(0, contentEnd - openEnd))
        return .ext(ExtensionBlockNode(
            extensionID: id,
            range: range,
            openFence: openFence,
            closeFence: closeFence,
            contentRange: contentRange,
            inlines: scoped && contentRange.length > 0
                ? InlineParser.parse(ns, range: contentRange, registry: registry) : []
        ))
    }

    /// ATX heading: optional indent, `#`×level, space(s), then inline content.
    /// Fork: or a setext heading, whose last line is its `===` (level 1) or `---` (level 2) marker.
    private static func heading(_ range: NSRange, _ ns: NSString, scoped: Bool = true, registry: ExtensionRegistry = .empty) -> BlockNode {
        let end = NSMaxRange(range)
        let firstLine = ns.lineRange(for: NSRange(location: range.location, length: 0))
        if NSMaxRange(firstLine) < end {
            let underline = ns.lineRange(for: NSRange(location: end - 1, length: 0))
            var markerEnd = NSMaxRange(underline)
            while markerEnd > underline.location, isLineBreak(ns.character(at: markerEnd - 1)) { markerEnd -= 1 }
            let level = ns.substring(with: underline).contains("=") ? 1 : 2
            var contentEnd = underline.location
            while contentEnd > range.location, isLineBreak(ns.character(at: contentEnd - 1)) { contentEnd -= 1 }
            let contentRange = NSRange(location: range.location, length: contentEnd - range.location)
            return .heading(level: level, range: range,
                            markers: [NSRange(location: underline.location, length: markerEnd - underline.location)],
                            inlines: scoped ? InlineParser.parse(ns, range: contentRange, registry: registry) : [])
        }
        var i = range.location
        while i < end, ns.character(at: i) == space || ns.character(at: i) == tab { i += 1 }
        let hashStart = i
        var level = 0
        while i < end, ns.character(at: i) == hash { level += 1; i += 1 }

        var contentStart = i
        while contentStart < end, ns.character(at: contentStart) == space { contentStart += 1 }
        // Markers span `#`(s) plus trailing space(s) so the whole syntax collapses on shrink.
        let markers = [NSRange(location: hashStart, length: contentStart - hashStart)]
        var contentEnd = end
        while contentEnd > contentStart, isLineBreak(ns.character(at: contentEnd - 1)) { contentEnd -= 1 }
        let contentRange = NSRange(location: contentStart, length: contentEnd - contentStart)

        return .heading(level: level, range: range, markers: markers,
                        inlines: scoped ? InlineParser.parse(ns, range: contentRange, registry: registry) : [])
    }

    /// Split a list block into physical items. Scoped passes derive their lines
    /// directly from the normalized scopes instead of walking the whole block.
    private static func list(
        _ range: NSRange,
        _ ns: NSString,
        scopedRanges: [NSRange]? = nil,
        registry: ExtensionRegistry = .empty
    ) -> BlockNode {
        let lineRanges: [NSRange]
        if let scopedRanges {
            var selected: [NSRange] = []
            for scope in scopedRanges {
                let intersection = NSIntersectionRange(scope, range)
                guard intersection.length > 0 else { continue }
                let expanded = NSIntersectionRange(
                    ns.lineRange(for: intersection),
                    range
                )
                var cursor = expanded.location
                let end = NSMaxRange(expanded)
                while cursor < end {
                    let line = NSIntersectionRange(
                        ns.lineRange(
                            for: NSRange(location: cursor, length: 0)
                        ),
                        range
                    )
                    if line.length > 0, selected.last != line {
                        selected.append(line)
                    }
                    let next = NSMaxRange(line)
                    guard next > cursor else { break }
                    cursor = next
                }
            }
            lineRanges = selected
        } else {
            var all: [NSRange] = []
            var cursor = range.location
            let end = NSMaxRange(range)
            while cursor < end {
                let line = ns.lineRange(
                    for: NSRange(location: cursor, length: 0)
                )
                all.append(line)
                cursor = NSMaxRange(line)
            }
            lineRanges = all
        }

        var items: [ListItem] = []
        items.reserveCapacity(lineRanges.count)
        for line in lineRanges {
            items.append(
                listItem(line, ns, scoped: true, registry: registry)
            )
        }
        return .list(range: range, items: items)
    }

    /// Fork: the list items on a quote's lines. Each line's `>` markers (each with an optional
    /// space or tab after it) come off first; the quote's own inlines cover the items' text.
    private static func quotedListItems(_ range: NSRange, _ ns: NSString) -> [ListItem] {
        var items: [ListItem] = []
        var lineStart = range.location
        while lineStart < NSMaxRange(range) {
            let line = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            lineStart = NSMaxRange(line)
            var i = line.location
            var indent = 0
            while i < lineStart, indent < 3, ns.character(at: i) == space || ns.character(at: i) == tab { i += 1; indent += 1 }
            guard i < lineStart, ns.character(at: i) == 0x3E else { continue }   // >
            while i < lineStart, ns.character(at: i) == 0x3E {
                i += 1
                if i < lineStart, ns.character(at: i) == space || ns.character(at: i) == tab { i += 1 }
            }
            guard BlockParser.isListItem(ns.substring(with: NSRange(location: i, length: lineStart - i))) else { continue }
            items.append(listItem(line, ns, from: i, scoped: false))
        }
        return items
    }

    /// Parse one list-item line: indent, marker, optional task checkbox, inline content.
    /// Fork: `start` is where the indent begins, after a quote's `>` markers.
    private static func listItem(_ lineRange: NSRange, _ ns: NSString, from start: Int? = nil, scoped: Bool = true,
                                 registry: ExtensionRegistry = .empty) -> ListItem {
        let end = NSMaxRange(lineRange)
        var i = start ?? lineRange.location
        var indent = 0
        while i < end, ns.character(at: i) == space || ns.character(at: i) == tab { i += 1; indent += 1 }
        let markerStart = i
        var ordered = false
        var number: Int?
        let c = i < end ? ns.character(at: i) : 0
        if c == 0x2D || c == 0x2A || c == 0x2B {        // - * +
            i += 1
        } else {                                        // N. / N)
            var value = 0
            var digits = 0
            while i < end, ns.character(at: i) >= 0x30, ns.character(at: i) <= 0x39, digits < 9 {
                value = value * 10 + Int(ns.character(at: i) - 0x30); i += 1; digits += 1
            }
            ordered = true
            number = value
            if i < end { i += 1 }                       // the `.` or `)`
        }
        let marker = NSRange(location: markerStart, length: i - markerStart)
        func isSpace(_ at: Int) -> Bool { at < end && (ns.character(at: at) == space || ns.character(at: at) == tab) }
        // Fork: GFM's rule (`TaskMarker.boxStart`): one to four spaces or tabs, the box, then a space or tab.
        let boxStart = TaskMarker.boxStart(in: { ns.character(at: $0) }, markerEnd: i, end: end)
        if isSpace(i) { i += 1 }
        var checkbox: NSRange?
        var checked = false
        var taskMarker: Character?
        if let box = boxStart {   // [ x ]
            let mid = ns.character(at: box + 1)
            checkbox = NSRange(location: box, length: 3)
            checked = (mid == 0x78 || mid == 0x58)
            taskMarker = Character(UnicodeScalar(mid)!)
            i = box + 4
        }
        var contentEnd = end
        while contentEnd > i, isLineBreak(ns.character(at: contentEnd - 1)) { contentEnd -= 1 }
        let content = NSRange(location: i, length: max(0, contentEnd - i))
        return ListItem(range: lineRange, marker: marker, ordered: ordered, number: number,
                        checkbox: checkbox, checked: checked, taskMarker: taskMarker, indent: indent,
                        contentRange: content, inlines: scoped ? InlineParser.parse(ns, range: content, registry: registry) : [])
    }

    private static func isLineBreak(_ c: unichar) -> Bool { c == 0x0A || c == 0x0D }
}
