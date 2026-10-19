//
//  MarkdownTable.swift
//  MarkdownEngine
//
//  Fork: a GFM table as cells, and back to padded markdown. Cells hold
//  `\n` where the file has `<br>` and an unescaped `|` where it has `\|`.
//  Row indices count the header as row 0.
//

import Foundation

package struct MarkdownTable: Equatable {

    package enum Alignment: Equatable {
        /// `---`: no marker. Draws like `.left`.
        case none
        case left
        case center
        case right
    }

    package var header: [String]
    package var alignments: [Alignment]
    package var rows: [[String]]
    /// The leading whitespace of the table's first line, kept on every line written.
    var indent = ""

    package var columnCount: Int { alignments.count }
    /// The header plus the body rows.
    package var rowCount: Int { 1 + rows.count }

    package init(header: [String], alignments: [Alignment], rows: [[String]], indent: String = "") {
        self.header = header
        self.alignments = alignments
        self.rows = rows
        self.indent = indent
    }

    package func cell(row: Int, column: Int) -> String {
        row == 0 ? header[column] : rows[row - 1][column]
    }

    // MARK: - Parsing

    /// Ragged rows are padded (or cut) to the wider of the header and the delimiter row.
    package static func parse(_ source: String) -> MarkdownTable? {
        let lines = source.components(separatedBy: CharacterSet.newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return nil }

        let header = parseRow(lines[0])
        let alignments = parseAlignments(lines[1])
        guard !header.isEmpty, !alignments.isEmpty else { return nil }

        let columnCount = max(header.count, alignments.count)
        func pad<T>(_ array: [T], with fill: T) -> [T] {
            array.count >= columnCount
                ? Array(array.prefix(columnCount))
                : array + Array(repeating: fill, count: columnCount - array.count)
        }
        return MarkdownTable(
            header: pad(header, with: ""),
            alignments: pad(alignments, with: .none),
            rows: lines.dropFirst(2).map { pad(parseRow($0), with: "") },
            indent: String(lines[0].prefix { $0 == " " || $0 == "\t" })
        )
    }

    /// Splits on UNESCAPED `|` only: a `|` after an odd run of backslashes is the cell's own (`\|`). GFM splits a row
    /// before inline parsing, so a cell holding `` `a \| b` `` is one cell. A backslash run before a `|` or at a
    /// cell's end is written doubled (`MarkdownTable.escape`), so any cell text round-trips.
    private static func parseRow(_ line: String) -> [String] {
        var s = Substring(line.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("|") { s = s.dropFirst() }
        if s.hasSuffix("|"), s.dropLast().reversed().prefix(while: { $0 == "\\" }).count % 2 == 0 { s = s.dropLast() }

        var cells: [String] = []
        var raw = ""
        var run = 0
        for ch in s {
            if ch == "\\" {
                run += 1
            } else if ch == "|", run % 2 == 0 {
                cells.append(finishCell(raw))
                raw = ""
                run = 0
                continue
            } else {
                run = 0
            }
            raw.append(ch)
        }
        cells.append(finishCell(raw))
        return cells
    }

    /// The text a cell's source stands for: backslash runs before an escaped `|` or at the end are halved.
    private static func decode(_ raw: String) -> String {
        var out = ""
        var run = 0
        func flush(followedByPipe: Bool, atEnd: Bool) {
            if followedByPipe { out += String(repeating: "\\", count: (run - 1) / 2) }
            else if atEnd, run % 2 == 0 { out += String(repeating: "\\", count: run / 2) }
            else { out += String(repeating: "\\", count: run) }
            run = 0
        }
        for ch in raw {
            if ch == "\\" { run += 1; continue }
            if ch == "|", run > 0 { flush(followedByPipe: true, atEnd: false) } else { flush(followedByPipe: false, atEnd: false) }
            out.append(ch)
        }
        flush(followedByPipe: false, atEnd: true)
        return out
    }

    private static func finishCell(_ raw: String) -> String {
        decode(raw.trimmingCharacters(in: .whitespaces)).replacingOccurrences(
            of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive]
        )
    }

    private static func parseAlignments(_ line: String) -> [Alignment] {
        parseRow(line).map { cell in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): return .center
            case (true, false): return .left
            case (false, true): return .right
            default: return .none
            }
        }
    }

    /// The cell a character offset in a table's source lands in: its row (the delimiter line reads as the header's),
    /// column, and the offset in the cell's trimmed text. Columns past the last read as the last.
    package static func cellLocation(in source: String, offset: Int) -> (row: Int, column: Int, offset: Int)? {
        let text = source as NSString
        guard text.length > 0 else { return nil }
        var start = 0
        var index = 0
        while start < text.length {
            let line = text.lineRange(for: NSRange(location: start, length: 0))
            var end = NSMaxRange(line)
            while end > line.location, [0x0A, 0x0D].contains(text.character(at: end - 1)) { end -= 1 }
            if offset < NSMaxRange(line) || NSMaxRange(line) >= text.length {
                let chars = (0..<(end - line.location)).map { text.character(at: line.location + $0) }
                let at = min(max(offset - line.location, 0), chars.count)
                var delimiters: [Int] = []
                var run = 0
                for (i, c) in chars.enumerated() {
                    if c == 0x5C { run += 1 } else {
                        if c == 0x7C, run % 2 == 0 { delimiters.append(i) }
                        run = 0
                    }
                }
                let leadingPipe = delimiters.first.map { first in chars[..<first].allSatisfy { $0 == 0x20 || $0 == 0x09 } } ?? false
                let before = delimiters.filter { $0 < at }.count
                let column = max(0, before - (leadingPipe ? 1 : 0))
                let cellStart = column + (leadingPipe ? 1 : 0) - 1 >= 0 && column + (leadingPipe ? 1 : 0) - 1 < delimiters.count
                    ? delimiters[column + (leadingPipe ? 1 : 0) - 1] + 1 : 0
                let cellEndIndex = column + (leadingPipe ? 1 : 0)
                let cellEnd = cellEndIndex < delimiters.count ? delimiters[cellEndIndex] : chars.count
                var textStart = cellStart
                while textStart < cellEnd, chars[textStart] == 0x20 || chars[textStart] == 0x09 { textStart += 1 }
                var textEnd = cellEnd
                while textEnd > textStart, chars[textEnd - 1] == 0x20 || chars[textEnd - 1] == 0x09 { textEnd -= 1 }
                return (index <= 1 ? 0 : index - 1, column, min(max(at - textStart, 0), textEnd - textStart))
            }
            start = NSMaxRange(line)
            index += 1
        }
        return nil
    }

    // MARK: - Writing

    /// The table's lines, columns padded to line up, without a trailing newline.
    package var markdown: String {
        let escaped = ([header] + rows).map { $0.map(Self.escape) }
        let widths = (0..<columnCount).map { column in
            max(3, escaped.map { $0[column].count }.max() ?? 0)
        }
        func line(_ cells: [String]) -> String {
            indent + "| " + zip(cells, widths).map { $0 + String(repeating: " ", count: $1 - $0.count) }
                .joined(separator: " | ") + " |"
        }
        let delimiter = zip(alignments, widths).map { alignment, width -> String in
            switch alignment {
            case .none: return String(repeating: "-", count: width)
            case .left: return ":" + String(repeating: "-", count: width - 1)
            case .right: return String(repeating: "-", count: width - 1) + ":"
            case .center: return ":" + String(repeating: "-", count: width - 2) + ":"
            }
        }
        return ([line(escaped[0]), line(delimiter)] + escaped.dropFirst().map(line)).joined(separator: "\n")
    }

    /// A cell's text as it is written: `|` as `\|`, line breaks as `<br>`, and a backslash run before a `|` or at the
    /// end doubled so the reader can tell it from the escape.
    private static func escape(_ cell: String) -> String {
        var out = ""
        var run = 0
        let characters = Array(cell)
        for (i, ch) in characters.enumerated() {
            if ch == "\\" {
                run += 1
                if i == characters.count - 1 { out += String(repeating: "\\", count: run * 2) }
                continue
            }
            out += String(repeating: "\\", count: ch == "|" ? run * 2 : run)
            run = 0
            switch ch {
            case "|": out += "\\|"
            case "\n": out += "<br>"
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: - Editing

    package mutating func setCell(row: Int, column: Int, to text: String) {
        if row == 0 { header[column] = text } else { rows[row - 1][column] = text }
    }

    /// A blank row at `index` (0...rowCount). At 0 it becomes the header.
    package mutating func insertRow(at index: Int) {
        let blank = [String](repeating: "", count: columnCount)
        if index == 0 {
            rows.insert(header, at: 0)
            header = blank
        } else {
            rows.insert(blank, at: index - 1)
        }
    }

    /// Deleting the header makes the next row the header. The only row stays:
    /// the caller removes the whole table.
    package mutating func deleteRow(at index: Int) {
        guard rowCount > 1 else { return }
        if index == 0 { header = rows.removeFirst() } else { rows.remove(at: index - 1) }
    }

    /// Moves a body row so it ends at `destination`. The header can't move and
    /// nothing moves above it.
    package mutating func moveRow(from index: Int, to destination: Int) {
        guard index > 0 else { return }
        let target = min(max(destination, 1), rowCount - 1)
        rows.insert(rows.remove(at: index - 1), at: target - 1)
    }

    package mutating func insertColumn(at index: Int) {
        header.insert("", at: index)
        alignments.insert(.none, at: index)
        for i in rows.indices { rows[i].insert("", at: index) }
    }

    /// The only column stays: the caller removes the whole table.
    package mutating func deleteColumn(at index: Int) {
        guard columnCount > 1 else { return }
        header.remove(at: index)
        alignments.remove(at: index)
        for i in rows.indices { rows[i].remove(at: index) }
    }

    package mutating func moveColumn(from index: Int, to destination: Int) {
        let target = min(max(destination, 0), columnCount - 1)
        func move<T>(_ array: inout [T]) { array.insert(array.remove(at: index), at: target) }
        move(&header)
        move(&alignments)
        for i in rows.indices { move(&rows[i]) }
    }

    package mutating func setAlignment(_ alignment: Alignment, column: Int) {
        alignments[column] = alignment
    }
}
