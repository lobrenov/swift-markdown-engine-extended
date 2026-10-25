//
//  BlockParser.swift
//  MarkdownEngine
//  Fork: changed from upstream; FORK.md lists the changes.
//
//  Phase 1 of the regex→AST refactor: the block-structure pass. Splits the
//  document into a flat, gap-free (tiling) sequence of blocks following the
//  CommonMark two-phase model — block structure first, inline content later.
//  Inline parsing happens per inline-bearing block in a separate step.
//
//  Ranges are absolute UTF-16 NSRanges into the source (the editor is
//  NSTextView / TextKit-2 based, so UTF-16 offsets are the native currency).
//  Storing relative widths (green-tree style, for cheap incremental reparse)
//  is a deliberate Phase 3 concern and intentionally deferred here.
//
//  Line classification mirrors the recognition the current regex tokenizer /
//  styler perform, so block ranges line up with today's tokens:
//    • heading        — headingRegex        `^\s*#{1,6} +…`
//    • thematic break — styler HR pattern   `^\s*(-{3,}|\*{3,}|_{3,})\s*$`
//    • fenced code    — codeBlockRegex       opening/closing ``` line
//    • blockquote     — blockquoteRegex     `^[ \t]{0,3}(>…)`
//

import Foundation

/// The block-level classification of a run of lines.
package enum BlockKind: Equatable {
    case paragraph       // inline-bearing
    case heading         // ATX line (`# …`), inline-bearing content
    case blockquote      // consecutive `>` lines, inline-bearing per line
    case list            // consecutive list-item lines (`-`/`*`/`+` or `1.`/`1)`)
    case fencedCode      // ```…``` or Fork: ~~~…~~~ — opaque (no inline parsing inside)
    case indentedCode    // Fork: lines indented 4+ columns after a non-paragraph — opaque
    case html            // Fork: a CommonMark HTML block — opaque
    case blockLatex      // $$…$$ — opaque
    case table           // GFM table — opaque (rendered as a unit)
    case thematicBreak   // `---` / `***` / `___` — produces no token today
    case blank           // blank / whitespace-only line(s) — separator
    case ext(String)     // extension-supplied fenced block (id), inline-bearing content
}

/// One block; `range` is the absolute UTF-16 span of its lines, tiling with no gaps.
package struct Block: Equatable {
    package let kind: BlockKind
    package let range: NSRange
}

/// A resolved contiguous change between two buffer states, in UTF-16 units.
/// `changeStart ..< changeEndOld` in the old buffer was replaced by
/// `changeStart ..< changeEndNew` in the new one. The region may be wider
/// than the minimal diff — splice logic only requires containment.
struct BufferDiff {
    let changeStart: Int
    let changeEndOld: Int
    let changeEndNew: Int
    let delta: Int
}

package enum BlockParser {

    private static let cacheLock = NSLock()
    private static var cachedChars: [unichar]?     // UTF-16 buffer of the last parse
    private static var cachedBlocks: [Block]?
    /// Registry fingerprint the memo was computed under — extension fences
    /// change the block structure of identical text.
    private static var cachedFingerprint: String = ""

    /// Splits `text` into gap-free tiling blocks; memoizes the last parse so both per-keystroke callers share one line-scan.
    /// Pass `utf16Chars` when the caller already extracted the buffer (must match `text`).
    static func parse(_ text: String, utf16Chars: [unichar]? = nil, registry: ExtensionRegistry = .empty) -> [Block] {
        let textNS = text as NSString
        let newLen = textNS.length
        let newChars: [unichar]
        if let utf16Chars, utf16Chars.count == newLen {
            newChars = utf16Chars
        } else {
            var buffer = [unichar](repeating: 0, count: newLen)
            if newLen > 0 { textNS.getCharacters(&buffer, range: NSRange(location: 0, length: newLen)) }
            newChars = buffer
        }

        cacheLock.lock()
        let prevChars = cachedFingerprint == registry.fingerprint ? cachedChars : nil
        let prevBlocks = cachedFingerprint == registry.fingerprint ? cachedBlocks : nil
        cacheLock.unlock()

        if let prevChars, let prevBlocks {
            // Identical text → memcmp hit (the scan below would walk O(doc)).
            if equalBuffers(prevChars, newChars) { return prevBlocks }
            if let diff = scanDiff(old: prevChars, new: newChars),
               let (incr, _) = incrementalParse(oldChars: prevChars, oldBlocks: prevBlocks, newChars: newChars, newNS: textNS, diff: diff, registry: registry) {
                cacheLock.lock(); cachedChars = newChars; cachedBlocks = incr; cachedFingerprint = registry.fingerprint; cacheLock.unlock()
                return incr
            }
        }

        let blocks = computeBlocks(text, registry: registry)
        cacheLock.lock(); cachedChars = newChars; cachedBlocks = blocks; cachedFingerprint = registry.fingerprint; cacheLock.unlock()
        return blocks
    }

    /// Adopt an externally computed parse (DocumentParseState publishes its
    /// per-keystroke result) so static-path callers — the restyle's
    /// DocumentAST.parse above all — take the memcmp hit instead of
    /// re-splicing against a one-keystroke-stale cache.
    static func seedCache(chars: [unichar], blocks: [Block], fingerprint: String = "") {
        cacheLock.lock(); cachedChars = chars; cachedBlocks = blocks; cachedFingerprint = fingerprint; cacheLock.unlock()
    }

    private static func equalBuffers(_ a: [unichar], _ b: [unichar]) -> Bool {
        guard a.count == b.count else { return false }
        if a.isEmpty { return true }
        return a.withUnsafeBytes { ap in
            b.withUnsafeBytes { bp in memcmp(ap.baseAddress!, bp.baseAddress!, ap.count) == 0 }
        }
    }

    /// Common prefix/suffix scan; nil when the buffers are identical.
    static func scanDiff(old: [unichar], new: [unichar]) -> BufferDiff? {
        let oldLen = old.count, newLen = new.count
        var p = 0
        let maxPre = min(oldLen, newLen)
        while p < maxPre, old[p] == new[p] { p += 1 }
        if p == oldLen, oldLen == newLen { return nil }
        var s = 0
        let maxSuf = maxPre - p
        while s < maxSuf, old[oldLen - 1 - s] == new[newLen - 1 - s] { s += 1 }
        return BufferDiff(changeStart: p, changeEndOld: oldLen - s, changeEndNew: newLen - s, delta: newLen - oldLen)
    }

    /// Does any LINE touched by `[lo, hi)` contain a `$$` or ``` that can ripple?
    /// Line-expanded, not just ±3 around the edit: block delimiters are
    /// line-classified with a TRIMMED prefix (`isBlockLatexOpen`), so editing
    /// the leading whitespace of an indented `$$` opener flips the pairing
    /// from arbitrarily far away from the literal `$$`. The boundary walk is
    /// capped; hitting the cap reports a delimiter (conservative full parse).
    static func hasBlockDelimiter(_ buf: [unichar], _ lo: Int, _ hi: Int, fences: [[unichar]] = []) -> Bool {
        let cap = 4096
        var start = max(0, lo - 3)
        var steps = 0
        while start > 0, buf[start - 1] != 0x0A, buf[start - 1] != 0x0D {
            start -= 1
            steps += 1
            if steps > cap { return true }
        }
        var end = min(buf.count, hi + 3)
        steps = 0
        while end < buf.count, buf[end] != 0x0A, buf[end] != 0x0D {
            end += 1
            steps += 1
            if steps > cap { return true }
        }
        var i = start
        var lineStart = start
        while i < end {
            if buf[i] == 0x0A || buf[i] == 0x0D { lineStart = i + 1 }
            if buf[i] == 0x24 {                                          // $
                if i + 1 < end, buf[i + 1] == 0x24 { return true }       // $$
            } else if buf[i] == 0x60, i + 2 < end, buf[i + 1] == 0x60, buf[i + 2] == 0x60 {
                return true                                              // ```
            } else if buf[i] == 0x7E, i + 2 < end, buf[i + 1] == 0x7E, buf[i + 2] == 0x7E {
                return true                                              // Fork: ~~~
            } else if buf[i] == 0x3C, isHTMLBlockDelimiter(buf, at: i, lineStart: lineStart, end: end) {
                return true                                              // Fork: an HTML block's opener or raw-text closer
            } else if buf[i] == 0x3E, i >= 1, buf[i - 1] == 0x3F
                        || (i >= 2 && ((buf[i - 1] == 0x2D && buf[i - 2] == 0x2D) || (buf[i - 1] == 0x5D && buf[i - 2] == 0x5D))) {
                return true                                              // Fork: `?>`, `-->`, `]]>`
            }
            // Extension fences pair with a distant partner exactly like ``` —
            // an edit touching one must force the full reparse too.
            for fence in fences where !fence.isEmpty && buf[i] == fence[0] {
                if i + fence.count <= end {
                    var match = true
                    for (k, u) in fence.enumerated() where buf[i + k] != u { match = false; break }
                    if match { return true }
                }
            }
            i += 1
        }
        return false
    }

    /// Fork: a `<` that can open an HTML block (first on its line after up to 3 spaces) or close a raw-text one.
    private static func isHTMLBlockDelimiter(_ buf: [unichar], at i: Int, lineStart: Int, end: Int) -> Bool {
        if i - lineStart <= 3, buf[lineStart..<i].allSatisfy({ $0 == 0x20 }) { return true }
        guard i + 1 < end, buf[i + 1] == 0x2F else { return false }
        for tag in ["script", "pre", "style", "textarea"] {
            let units = Array(tag.utf16)
            guard i + 2 + units.count <= end else { continue }
            if units.enumerated().allSatisfy({ buf[i + 2 + $0.offset] | 0x20 == $0.element }) { return true }
        }
        return false
    }

    /// Fork: whether lines indented 4 columns after `blocks` continue a list (so aren't indented code):
    /// the last non-blank block is a list, or a paragraph straight after one (a lazy line). `prefix` stands
    /// for the blocks before `blocks` when it runs out.
    static func listContext(_ blocks: ArraySlice<Block>, prefix: (inList: Bool, lastIsList: Bool) = (false, false)) -> Bool {
        var i = blocks.endIndex - 1
        while i >= blocks.startIndex, blocks[i].kind == .blank { i -= 1 }
        guard i >= blocks.startIndex else { return prefix.inList }
        switch blocks[i].kind {
        case .list: return true
        case .paragraph: return i > blocks.startIndex ? blocks[i - 1].kind == .list : prefix.lastIsList
        default: return false
        }
    }

    /// Fork: the run of `new` blocks that differ from `old` once the unchanged prefix and the suffix (moved by
    /// `delta`) are set aside; nil when none differ.
    static func changedRange(old: [Block], new: [Block], delta: Int) -> ClosedRange<Int>? {
        var head = 0
        while head < old.count, head < new.count, old[head] == new[head] { head += 1 }
        var tail = 0
        while tail < old.count - head, tail < new.count - head {
            let o = old[old.count - 1 - tail], n = new[new.count - 1 - tail]
            guard o.kind == n.kind, o.range.length == n.range.length, o.range.location + delta == n.range.location else { break }
            tail += 1
        }
        let last = new.count - 1 - tail
        return head <= last ? head...last : nil
    }

    /// Splice-parse against a precomputed change region (descriptor- or scan-derived):
    /// reparse the affected block window, splice between untouched prefix/suffix; nil to fall back to full.
    static func incrementalParse(oldChars o: [unichar], oldBlocks: [Block], newChars n: [unichar], newNS: NSString, diff: BufferDiff, registry: ExtensionRegistry = .empty) -> (blocks: [Block], window: Int)? {
        guard !oldBlocks.isEmpty else { return nil }
        let oldLen = o.count, newLen = n.count
        guard oldLen > 0, newLen > 0 else { return nil }

        let delta = diff.delta
        let changeStart = diff.changeStart
        let changeEnd = diff.changeEndOld       // [changeStart, changeEnd) in old
        guard changeStart >= 0, changeEnd <= oldLen, diff.changeEndNew <= newLen,
              changeStart <= changeEnd, changeStart <= diff.changeEndNew else { return nil }

        // A fence/block-LaTeX/extension delimiter in the edit can pair with a distant partner → full reparse.
        let fences = registry.blockEntries.map(\.fenceChars)
        if hasBlockDelimiter(o, changeStart, changeEnd, fences: fences)
            || hasBlockDelimiter(n, changeStart, diff.changeEndNew, fences: fences) {
            return nil
        }

        // 2. Affected old-block window (±1 block margin for merges/splits).
        // Blocks tile the document in order — binary search instead of the
        // linear walks that cost O(#blocks) per keystroke in large documents.
        var lo = 0, hi = oldBlocks.count - 1
        while lo < hi {                       // last block starting <= changeStart
            let m = (lo + hi + 1) / 2
            if oldBlocks[m].range.location <= changeStart { lo = m } else { hi = m - 1 }
        }
        let firstIdx = lo
        lo = 0; hi = oldBlocks.count - 1
        while lo < hi {                       // first block ending >= changeEnd
            let m = (lo + hi) / 2
            if NSMaxRange(oldBlocks[m].range) >= changeEnd { hi = m } else { lo = m + 1 }
        }
        let lastIdx = lo
        let winFirst = max(0, min(firstIdx, lastIdx) - 1)
        var winLast = min(oldBlocks.count - 1, max(firstIdx, lastIdx) + 1)

        // 3. Opaque multi-line blocks (fences / block LaTeX) in the window are
        // fine for INTERIOR edits: the window contains each block wholly, the
        // ±3 delimiter guard above already bailed on any edit that creates,
        // destroys, or touches a ``` / $$ pairing, and an edit that UN-closes
        // a block (trailing chars on its closer line) makes the reparsed block
        // reach the window end — caught by the trailing guard below. Typing
        // inside a code block used to fall back to a full O(doc) reparse on
        // every keystroke because of an unconditional bail here.

        // 4. Window → new-text range (window start is before the edit → unchanged).
        let winStart = oldBlocks[winFirst].range.location
        let prefixContext = (inList: listContext(oldBlocks[0..<winFirst]),
                             lastIsList: winFirst > 0 && oldBlocks[winFirst - 1].kind == .list)
        // 5. Reparse just the window substring, shift to absolute new coords.
        // Fork: until it ends as the old parse did there. A lazy line or a list's indented
        // line can move a boundary past the ±1 margin; each miss widens the window by a block.
        var winEndNew = 0
        var reparsed: [Block] = []
        for attempt in 0... {
            winEndNew = NSMaxRange(oldBlocks[winLast].range) + delta
            guard winStart >= 0, winEndNew >= winStart, winEndNew <= newLen else { return nil }
            let windowText = newNS.substring(with: NSRange(location: winStart, length: winEndNew - winStart))
            reparsed = computeBlocks(windowText, registry: registry, prefix: prefixContext).map { $0.shifted(by: winStart) }
            let margin = oldBlocks[winLast].shifted(by: delta)
            if winLast == oldBlocks.count - 1 || reparsed.last == margin { break }
            guard attempt < 16 else { return nil }
            winLast += 1
        }
        // A trailing fence/latex/extension block reaching the window end might continue past it.
        if let last = reparsed.last, NSMaxRange(last.range) >= winEndNew {
            switch last.kind {
            case .fencedCode, .blockLatex, .ext, .html, .indentedCode: return nil
            case .paragraph:
                // The edit may have dissolved the separator that used to end
                // this paragraph (backspace-joining two paragraphs): if the
                // suffix ALSO starts with a paragraph, the two would need to
                // MERGE — a full parse never yields adjacent paragraphs. The
                // splice can't merge across the cut, so fall back.
                if winLast + 1 < oldBlocks.count, oldBlocks[winLast + 1].kind == .paragraph {
                    return nil
                }
            default: break
            }
        }

        // Fork: an HTML block ends far from its opener and absorbs whatever it covers (a fence opener, a
        // list), so an edit in or next to one parses in full.
        if oldBlocks[winFirst...winLast].contains(where: { $0.kind == .html }) || reparsed.contains(where: { $0.kind == .html }) {
            return nil
        }

        // Fork: the suffix's first non-blank block reads indented lines by the list context the window ends
        // in, and indented code joins across blank lines: either change needs the full parse.
        let suffix = oldBlocks[(winLast + 1)...]
        if let next = suffix.first(where: { $0.kind != .blank }) {
            let lastReparsed = reparsed.last(where: { $0.kind != .blank })?.kind
            if next.kind == .indentedCode, lastReparsed == .indentedCode { return nil }
            let oldContext = listContext(oldBlocks[0...winLast])
            let newContext = listContext(reparsed[...], prefix: prefixContext)
            if oldContext != newContext {
                let firstLine = newNS.lineRange(for: NSRange(location: next.range.location + delta, length: 0))
                if next.kind == .indentedCode || isIndentedCode(newNS.substring(with: firstLine)) { return nil }
            }
        }

        // 6. Splice: prefix (unchanged) + reparsed window + suffix (shifted).
        var result: [Block] = []
        result.append(contentsOf: oldBlocks[0..<winFirst])
        result.append(contentsOf: reparsed)
        if winLast + 1 < oldBlocks.count {
            result.append(contentsOf: oldBlocks[(winLast + 1)...].map { $0.shifted(by: delta) })
        }

        // 7. Validate gap-free tiling of [0, newLen); else full reparse.
        var cursor = 0
        for b in result {
            if b.range.location != cursor { return nil }
            cursor = NSMaxRange(b.range)
        }
        guard cursor == newLen else { return nil }
        return (result, reparsed.count)
    }

    /// Fork: `prefix` is the list context of the blocks before `text` (see `listContext`).
    static func computeBlocks(_ text: String, registry: ExtensionRegistry = .empty,
                              prefix: (inList: Bool, lastIsList: Bool) = (false, false)) -> [Block] {
        let nsText = text as NSString
        let length = nsText.length
        guard length > 0 else { return [] }

        // 1. Slice into physical lines (each includes its trailing newline).
        var lines: [NSRange] = []
        var cursor = 0
        while cursor < length {
            let r = nsText.lineRange(for: NSRange(location: cursor, length: 0))
            lines.append(r)
            cursor = NSMaxRange(r)
        }

        func lineText(_ i: Int) -> String { nsText.substring(with: lines[i]) }

        /// Line index of the fence closing a code block opened at `start`; nil when unclosed.
        /// Fork: the closer is the opener's character, at least as many, and nothing else.
        func fenceCloseIndex(from start: Int) -> Int? {
            guard let open = fenceOpening(lineText(start)) else { return nil }
            var scan = start + 1
            while scan < lines.count {
                if isFenceClose(lineText(scan), matching: open) { return scan }
                scan += 1
            }
            return nil
        }

        /// Fork: the last line of an HTML block of `type` opened at `start`.
        func htmlBlockEnd(type: Int, from start: Int) -> Int {
            if type <= 5 {
                var scan = start
                while scan < lines.count {
                    if htmlBlockCloses(lineText(scan), type: type) { return scan }
                    scan += 1
                }
                return lines.count - 1
            }
            var end = start
            while end + 1 < lines.count, !isBlank(lineText(end + 1)) { end += 1 }
            return end
        }

        /// Line index of the `$$` closing a block-LaTeX run opened at `start`; nil if none.
        func blockLatexCloseIndex(from start: Int) -> Int? {
            let open = lineText(start).trimmingCharacters(in: .whitespacesAndNewlines)
            if open.dropFirst(2).contains("$$") { return start }
            var j = start + 1
            while j < lines.count { if lineText(j).contains("$$") { return j }; j += 1 }
            return nil
        }

        // 2. Classify + group.
        var blocks: [Block] = []
        var i = 0
        while i < lines.count {
            let line = lineText(i)

            if isBlank(line) {
                var end = i
                while end + 1 < lines.count, isBlank(lineText(end + 1)) { end += 1 }
                blocks.append(Block(kind: .blank, range: union(lines[i...end])))
                i = end + 1

            } else if isIndentedCode(line), !listContext(blocks[...], prefix: prefix) {
                // Fork: indented code (a paragraph would have taken the line as a continuation),
                // through its last indented line; blank lines inside stay in it. Not in a list's context,
                // whose indented lines are its continuation.
                var end = i
                var scan = i + 1
                while scan < lines.count {
                    let next = lineText(scan)
                    if isIndentedCode(next) { end = scan } else if !isBlank(next) { break }
                    scan += 1
                }
                blocks.append(Block(kind: .indentedCode, range: union(lines[i...end])))
                i = end + 1

            } else if isFence(line), let end = fenceCloseIndex(from: i) {
                blocks.append(Block(kind: .fencedCode, range: union(lines[i...end])))
                i = end + 1

            } else if let type = htmlBlockStart(line) {
                let end = htmlBlockEnd(type: type, from: i)
                blocks.append(Block(kind: .html, range: union(lines[i...end])))
                i = end + 1

            } else if isThematicBreak(line) {
                blocks.append(Block(kind: .thematicBreak, range: lines[i]))
                i += 1

            } else if isHeading(line) {
                blocks.append(Block(kind: .heading, range: lines[i]))
                i += 1

            } else if isBlockquote(line) {
                var end = i
                while end + 1 < lines.count, isBlockquote(lineText(end + 1)) { end += 1 }
                blocks.append(Block(kind: .blockquote, range: union(lines[i...end])))
                i = end + 1

            } else if isListItem(line) {
                // Consecutive list-item lines form one list block; per-item detail is parsed in DocumentAST.
                var end = i
                while end + 1 < lines.count, isListItem(lineText(end + 1)) { end += 1 }
                blocks.append(Block(kind: .list, range: union(lines[i...end])))
                i = end + 1

            } else if isTableRow(line), i + 1 < lines.count, isTableSeparator(lineText(i + 1), header: line) {
                // GFM table: a `|…|` header, a `|-…-|` separator, then data rows.
                var end = i + 1
                while end + 1 < lines.count, isTableRow(lineText(end + 1)) { end += 1 }
                blocks.append(Block(kind: .table, range: union(lines[i...end])))
                i = end + 1

            } else if isBlockLatexOpen(line), let end = blockLatexCloseIndex(from: i) {
                // Block LaTeX `$$…$$` — a single line or a `$$`-delimited run.
                blocks.append(Block(kind: .blockLatex, range: union(lines[i...end])))
                i = end + 1

            } else if let entry = registry.blockEntry(opening: line) {
                // Extension fenced block: consume through the closing fence
                // line (or to EOF if none) — mirrors ``` semantics. Built-ins
                // classify first, so a fence colliding with a built-in line
                // form never reaches here.
                var end = lines.count - 1
                var scan = i + 1
                while scan < lines.count {
                    if lineText(scan).hasPrefix(entry.fence) { end = scan; break }
                    scan += 1
                }
                blocks.append(Block(kind: .ext(entry.id), range: union(lines[i...end])))
                i = end + 1

            } else {
                // Paragraph: merge consecutive plain (non-blank, non-special) lines.
                var end = i
                while end + 1 < lines.count {
                    let next = lineText(end + 1)
                    if isBlank(next) { break }
                    // An indented line continues the paragraph, whatever it looks like.
                    if isIndentedCode(next) { end += 1; continue }
                    if isThematicBreak(next) || isHeading(next) || isBlockquote(next) || (isListItem(next) && !isEmptyListItem(next)) { break }
                    if let type = htmlBlockStart(next), type <= 6 { break }
                    // A table (row + separator), a CLOSED code fence, a
                    // block-LaTeX run, or an extension fence interrupts it —
                    // an unclosed opener stays part of the paragraph.
                    if isFence(next), fenceCloseIndex(from: end + 1) != nil { break }
                    if isTableRow(next), end + 2 < lines.count, isTableSeparator(lineText(end + 2), header: next) { break }
                    if isBlockLatexOpen(next), blockLatexCloseIndex(from: end + 1) != nil { break }
                    if registry.blockEntry(opening: next) != nil { break }
                    end += 1
                }
                blocks.append(Block(kind: .paragraph, range: union(lines[i...end])))
                i = end + 1
            }
        }
        return blocks
    }

    // MARK: - Line classification

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// An opening fence line. Fork: up to 3 spaces, then 3+ backticks (no backtick after) or 3+ tildes.
    private static func isFence(_ line: String) -> Bool {
        fenceOpening(line) != nil
    }

    /// Fork: the fence character and run length of an opening fence line.
    package static func fenceOpening(_ line: String) -> (character: Character, count: Int)? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let c = rest.first, c == "`" || c == "~" else { return nil }
        let count = rest.prefix { $0 == c }.count
        guard count >= 3 else { return nil }
        if c == "`", rest.dropFirst(count).contains("`") { return nil }
        return (c, count)
    }

    /// Fork: a closing fence for `open`: up to 3 spaces, at least as many of its character, then only whitespace.
    private static func isFenceClose(_ line: String, matching open: (character: Character, count: Int)) -> Bool {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return false }
        let rest = line.dropFirst(indent)
        let count = rest.prefix { $0 == open.character }.count
        return count >= open.count && rest.dropFirst(count).allSatisfy(\.isWhitespace)
    }

    /// Fork: a line indented 4 or more columns (a tab reaches the next multiple of 4), with content.
    private static func isIndentedCode(_ line: String) -> Bool {
        var column = 0
        for c in line {
            if c == " " { column += 1 } else if c == "\t" { column += 4 - column % 4 } else { break }
            if column >= 4 { return !isBlank(line) }
        }
        return false
    }

    private static let htmlRawTags = ["script", "pre", "style", "textarea"]
    private static let htmlBlockTags: Set<String> = [
        "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col",
        "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure",
        "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr", "html",
        "iframe", "legend", "li", "link", "main", "menu", "menuitem", "nav", "noframes", "ol", "optgroup",
        "option", "p", "param", "search", "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead",
        "title", "tr", "track", "ul",
    ]

    /// Fork: the CommonMark HTML block type (1–7) a line opens, if any.
    static func htmlBlockStart(_ line: String) -> Int? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent).trimmingCharacters(in: .newlines)
        guard rest.hasPrefix("<") else { return nil }
        let lower = rest.lowercased()
        for tag in htmlRawTags where lower.hasPrefix("<" + tag) {
            let after = lower.dropFirst(tag.count + 1).first
            if after == nil || after == " " || after == "\t" || after == ">" { return 1 }
        }
        if rest.hasPrefix("<!--") { return 2 }
        if rest.hasPrefix("<?") { return 3 }
        if rest.hasPrefix("<![CDATA[") { return 5 }
        if rest.hasPrefix("<!"), let c = rest.dropFirst(2).first, c.isASCII, c.isLetter { return 4 }
        let name = lower.dropFirst(lower.hasPrefix("</") ? 2 : 1).prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        if htmlBlockTags.contains(String(name)) {
            let after = lower.dropFirst((lower.hasPrefix("</") ? 2 : 1) + name.count)
            if after.isEmpty || after.hasPrefix(" ") || after.hasPrefix("\t") || after.hasPrefix(">") || after.hasPrefix("/>") {
                return 6
            }
        }
        if isCompleteTagLine(rest) { return 7 }
        return nil
    }

    /// Fork: an open or closing tag, then only whitespace (type 7).
    private static func isCompleteTagLine(_ line: String) -> Bool {
        let pattern = #"^(?:<[A-Za-z][A-Za-z0-9-]*(?:\s+[A-Za-z_:][A-Za-z0-9_.:-]*(?:\s*=\s*(?:[^\s"'=<>`]+|'[^']*'|"[^"]*"))?)*\s*/?>|</[A-Za-z][A-Za-z0-9-]*\s*>)\s*$"#
        return line.range(of: pattern, options: .regularExpression) != nil
    }

    /// Fork: whether `line` ends an HTML block of `type` (1–5).
    private static func htmlBlockCloses(_ line: String, type: Int) -> Bool {
        switch type {
        case 1: let l = line.lowercased(); return htmlRawTags.contains { l.contains("</\($0)>") }
        case 2: return line.contains("-->")
        case 3: return line.contains("?>")
        case 4: return line.contains(">")
        default: return line.contains("]]>")
        }
    }

    /// `^\s*(-{3,}|\*{3,}|_{3,})\s*$` — a solid run of 3+ of one of `- * _`.
    private static func isThematicBreak(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 3, let first = t.first,
              first == "-" || first == "*" || first == "_" else { return false }
        return t.allSatisfy { $0 == first }
    }

    /// `^\s*#{1,6} +…` — 1–6 hashes after optional indent, then at least one space.
    private static func isHeading(_ line: String) -> Bool {
        var rest = Substring(line).drop { $0 == " " || $0 == "\t" }
        var hashes = 0
        while let c = rest.first, c == "#" { hashes += 1; rest = rest.dropFirst() }
        guard (1...6).contains(hashes) else { return false }
        return rest.first == " "
    }

    /// `^[ \t]{0,3}>…` — up to 3 leading spaces/tabs, then a `>`.
    private static func isBlockquote(_ line: String) -> Bool {
        var rest = Substring(line)
        var indent = 0
        while indent < 3, let c = rest.first, c == " " || c == "\t" {
            rest = rest.dropFirst(); indent += 1
        }
        return rest.first == ">"
    }

    /// A list-item line: optional indent, a bullet (`-`/`*`/`+`) or ordered marker (`1.`/`1)`), then a space/tab.
    /// Fork: or nothing, as CommonMark's empty item (`-`, `1.`).
    static func isListItem(_ line: String) -> Bool {
        var rest = Substring(line).drop { $0 == " " || $0 == "\t" }
        guard let first = rest.first else { return false }
        if first == "-" || first == "*" || first == "+" {
            rest = rest.dropFirst()
        } else if first.isNumber {
            var digits = 0
            while let c = rest.first, c.isNumber, digits < 9 { rest = rest.dropFirst(); digits += 1 }
            guard let d = rest.first, d == "." || d == ")" else { return false }
            rest = rest.dropFirst()
        } else {
            return false
        }
        guard let after = rest.first else { return true }
        return after == " " || after == "\t" || after.isNewline
    }

    /// Fork: a list-item line with nothing after its marker. It can't interrupt a paragraph.
    static func isEmptyListItem(_ line: String) -> Bool {
        guard isListItem(line) else { return false }
        var rest = Substring(line).drop { $0 == " " || $0 == "\t" }
        rest = rest.drop { $0.isNumber }.dropFirst()
        return rest.allSatisfy { $0 == " " || $0 == "\t" || $0.isNewline }
    }

    /// A GFM table row. Fork: any line holding an unescaped `|`; the outer pipes are optional.
    static func isTableRow(_ line: String) -> Bool {
        guard line.utf8.contains(UInt8(ascii: "|")) else { return false }
        return tableCells(line).count > 1 || {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.count >= 2 && t.hasPrefix("|") && t.hasSuffix("|")
        }()
    }

    /// A GFM delimiter row: cells of `:?-+:?`. Fork: outer pipes optional, as many cells as `header`.
    static func isTableSeparator(_ line: String, header: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.contains("|") else { return false }
        let cells = tableCells(line)
        guard !cells.isEmpty, cells.count == tableCells(header).count else { return false }
        return cells.allSatisfy { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            let dashes = c.drop { $0 == ":" }.reversed().drop { $0 == ":" }
            return !dashes.isEmpty && dashes.allSatisfy { $0 == "-" } && c.filter { $0 == ":" }.count <= 2
        }
    }

    /// Fork: a row's cells, split on unescaped pipes, without the outer ones.
    private static func tableCells(_ line: String) -> [Substring] {
        var t = Substring(line.trimmingCharacters(in: .whitespacesAndNewlines))
        if t.hasPrefix("|") { t = t.dropFirst() }
        if t.hasSuffix("|"), !t.hasSuffix("\\|") { t = t.dropLast() }
        var cells: [Substring] = []
        var start = t.startIndex
        var escaped = false
        for i in t.indices {
            if escaped { escaped = false; continue }
            if t[i] == "\\" { escaped = true } else if t[i] == "|" { cells.append(t[start..<i]); start = t.index(after: i) }
        }
        cells.append(t[start...])
        return cells
    }

    /// A block-LaTeX opener: a line whose content starts with `$$`.
    private static func isBlockLatexOpen(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("$$")
    }

    private static func union(_ ranges: ArraySlice<NSRange>) -> NSRange {
        let lo = ranges.first!.location
        let hi = NSMaxRange(ranges.last!)
        return NSRange(location: lo, length: hi - lo)
    }
}

private extension Block {
    /// A copy with the range moved by `d` UTF-16 units.
    func shifted(by d: Int) -> Block {
        Block(kind: kind, range: NSRange(location: range.location + d, length: range.length))
    }
}
