//
//  MarkdownTable+Source.swift
//  MarkdownEngine
//
//  Fork: writes a changed `MarkdownTable` over the source it was read from, touching only the lines the change
//  needs and, in those, only the cells it needs. Untouched lines and cells keep their exact text, spacing and escapes.
//

import Foundation

extension MarkdownTable {

    /// What changed between the table read from the source and the table to write.
    package enum Change: Equatable {
        /// Cell text or alignments, the same rows and columns.
        case edit
        case insertRow(Int)
        case deleteRow(Int)
        case moveRow(from: Int, to: Int)
        case insertColumn(Int)
        case deleteColumn(Int)
        case moveColumn(from: Int, to: Int)
    }

    /// `source` (the table's lines, parsed as `old`) with this table's changes written in. A row change touches the
    /// affected lines; a column change touches every line, rewriting only each line's cells list; a cell edit
    /// touches only the cell's line, keeping its spacing (padded to the column's width where the column is padded);
    /// an alignment change rewrites only its delimiter cell. New rows follow the neighbouring row's style. A source
    /// whose lines don't match `old` is written whole (`markdown`).
    package func markdown(replacing source: String, from old: MarkdownTable, change: Change) -> String {
        guard let lines = SourceLine.split(source), lines.count == old.rowCount + 1 else { return markdown }
        let columns = old.columnCount
        let sourceRows = lines.map { SourceRow($0.text) }
        let widths = Self.paddedWidths(sourceRows, columns: columns)

        // The old row each new row is read from; nil is a new row.
        var rowSource: [Int?] = (0..<rowCount).map { $0 }
        switch change {
        case .edit, .insertColumn, .deleteColumn, .moveColumn:
            guard rowCount == old.rowCount else { return markdown }
        case .insertRow(let index):
            rowSource = (0..<old.rowCount + 1).map { $0 < index ? $0 : $0 == index ? nil : $0 - 1 }
        case .deleteRow(let index):
            rowSource = (0..<old.rowCount - 1).map { $0 < index ? $0 : $0 + 1 }
        case .moveRow(let from, let to):
            var order = Array(0..<old.rowCount)
            order.insert(order.remove(at: from), at: min(max(to, 1), old.rowCount - 1))
            rowSource = order
        }
        switch change {
        case .edit, .insertRow, .deleteRow, .moveRow:
            guard columnCount == columns else { return markdown }
        default: break
        }

        func lineIndex(_ row: Int) -> Int { row == 0 ? 0 : row + 1 }
        var out: [(text: String, separator: String)] = []
        for newLine in 0..<rowCount + 1 {
            let newRow = newLine == 0 ? 0 : newLine - 1
            let source: Int? = newLine == 1 ? 1 : rowSource[newRow].map(lineIndex)
            guard let source else {
                out.append((blankLine(change: change, lines: lines, rows: sourceRows, widths: widths), ""))
                continue
            }
            let line = lines[source]
            let text: String
            switch change {
            case .edit:
                text = editedLine(line.text, newLine: newLine, old: old, widths: widths)
            case .insertColumn, .deleteColumn, .moveColumn:
                text = columnLine(sourceRows[source], newLine: newLine, change: change, widths: widths)
            default:
                text = line.text
            }
            out.append((text, line.separator))
        }

        let dominant = lines.first { !$0.separator.isEmpty }?.separator ?? "\n"
        var result = ""
        for (i, line) in out.enumerated() {
            result += line.text
            if i < out.count - 1 { result += line.separator.isEmpty ? dominant : line.separator }
        }
        return result + lines[lines.count - 1].separator
    }

    // MARK: - Cell edits

    private func editedLine(_ text: String, newLine: Int, old: MarkdownTable, widths: [Int?]) -> String {
        let row = newLine == 0 ? 0 : newLine - 1
        let changed: [Int]
        if newLine == 1 {
            changed = (0..<columnCount).filter { alignments[$0] != old.alignments[$0] }
        } else {
            changed = (0..<columnCount).filter { cell(row: row, column: $0) != old.cell(row: row, column: $0) }
        }
        guard !changed.isEmpty else { return text }
        var parsed = SourceRow(text)
        guard parsed.cells.count == columnCount else { return freshLine(newLine) }
        for column in changed {
            parsed.cells[column] = newLine == 1
                ? Self.delimiterCell(parsed.cells[column], alignments[column])
                : Self.rewrite(parsed.cells[column], to: cell(row: row, column: column), padded: widths[column])
        }
        return parsed.text
    }

    /// A cell's source with its text replaced: its spacing stays, and a padded column's width too.
    private static func rewrite(_ raw: String, to text: String, padded width: Int?) -> String {
        if finishCell(raw) == text { return raw }
        let content = escape(text)
        let isBlank: (Character) -> Bool = { $0 == " " || $0 == "\t" }
        var lead = String(raw.prefix(while: isBlank))
        var trail = String(raw.reversed().prefix(while: isBlank).reversed())
        if lead.count == raw.count {
            lead = raw.isEmpty ? "" : String(raw.prefix(1))
            trail = raw.isEmpty ? "" : " "
        }
        if let width {
            let fill = width - lead.count - content.count
            return lead + content + String(repeating: " ", count: max(fill, 1))
        }
        return lead + content + trail
    }

    /// A delimiter cell's source for `alignment`: its spacing and dash count stay.
    private static func delimiterCell(_ raw: String, _ alignment: Alignment) -> String {
        let isBlank: (Character) -> Bool = { $0 == " " || $0 == "\t" }
        let lead = raw.prefix(while: isBlank)
        let trail = raw.reversed().prefix(while: isBlank).reversed()
        let width = max(3, raw.trimmingCharacters(in: .whitespaces).count)
        return String(lead) + delimiterCore(alignment, width: width) + String(trail)
    }

    private static func delimiterCore(_ alignment: Alignment, width: Int) -> String {
        switch alignment {
        case .none: return String(repeating: "-", count: width)
        case .left: return ":" + String(repeating: "-", count: width - 1)
        case .right: return String(repeating: "-", count: width - 1) + ":"
        case .center: return ":" + String(repeating: "-", count: width - 2) + ":"
        }
    }

    // MARK: - Column changes

    private func columnLine(_ source: SourceRow, newLine: Int, change: Change, widths: [Int?]) -> String {
        var row = source
        guard row.cells.count == widths.count else { return freshLine(newLine) }
        switch change {
        case .insertColumn(let index):
            let template = index > 0 ? index - 1 : index
            let raw = row.cells[template]
            row.cells.insert(newLine == 1 ? Self.delimiterCell(raw, .none) : Self.blankCell(like: raw, padded: widths[template]),
                             at: index)
        case .deleteColumn(let index):
            row.cells.remove(at: index)
        case .moveColumn(let from, let to):
            row.cells.insert(row.cells.remove(at: from), at: min(max(to, 0), widths.count - 1))
        default:
            break
        }
        return row.text
    }

    // MARK: - New rows

    /// A new body row (or header) in the style of the row next to it.
    private func blankLine(change: Change, lines: [SourceLine], rows: [SourceRow], widths: [Int?]) -> String {
        guard case .insertRow(let index) = change else { return freshBlank() }
        let template = index == 0 ? 0 : index + 1 < lines.count ? index + 1 : index >= 2 ? index : 0
        var row = rows[template]
        guard row.cells.count == widths.count else { return freshBlank() }
        row.cells = zip(row.cells, widths).map { Self.blankCell(like: $0, padded: $1) }
        return row.text
    }

    private static func blankCell(like raw: String, padded width: Int?) -> String {
        if let width { return String(repeating: " ", count: width) }
        let isBlank: (Character) -> Bool = { $0 == " " || $0 == "\t" }
        if raw.allSatisfy(isBlank) { return raw }
        let lead = raw.prefix(while: isBlank)
        return String(lead) + (isBlank(raw.last!) ? " " : "")
    }

    private func freshBlank() -> String {
        indent + "| " + [String](repeating: "", count: columnCount).joined(separator: " | ") + " |"
    }

    /// Line `newLine` written whole in the default style.
    private func freshLine(_ newLine: Int) -> String {
        let cells: [String]
        if newLine == 1 {
            cells = alignments.map { Self.delimiterCore($0, width: 3) }
        } else {
            cells = (newLine == 0 ? header : rows[newLine - 2]).map(Self.escape)
        }
        return indent + "| " + cells.joined(separator: " | ") + " |"
    }

    // MARK: - Source lines

    /// A column's source width when its cells are padded to line up (equal widths, some with two or more trailing
    /// spaces); nil when they aren't, or when a line doesn't have `columns` cells.
    private static func paddedWidths(_ rows: [SourceRow], columns: Int) -> [Int?] {
        guard rows.allSatisfy({ $0.cells.count == columns }) else { return [Int?](repeating: nil, count: columns) }
        return (0..<columns).map { column in
            let raws = rows.map { $0.cells[column] }
            guard let width = raws.first?.count, raws.allSatisfy({ $0.count == width }),
                  raws.contains(where: { $0.hasSuffix("  ") }) else { return nil }
            return width
        }
    }

    fileprivate struct SourceLine {
        var text: String
        var separator: String

        /// The table's lines with their line breaks; nil when one is blank.
        static func split(_ source: String) -> [SourceLine]? {
            let text = source as NSString
            var lines: [SourceLine] = []
            var start = 0
            while start < text.length {
                let range = text.lineRange(for: NSRange(location: start, length: 0))
                var end = NSMaxRange(range)
                while end > range.location, "\n\r\u{2028}\u{2029}\u{85}".utf16.contains(text.character(at: end - 1)) { end -= 1 }
                let content = text.substring(with: NSRange(location: range.location, length: end - range.location))
                guard !content.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                lines.append(SourceLine(text: content, separator: text.substring(with: NSRange(location: end, length: NSMaxRange(range) - end))))
                start = NSMaxRange(range)
            }
            return lines
        }
    }

    /// A line as its pieces, each cell's source between the pipes included: `text` joins them back exactly.
    fileprivate struct SourceRow {
        var indent: String
        var leading: Bool
        var trailing: Bool
        var tail: String
        var cells: [String]

        init(_ line: String) {
            let isBlank: (Character) -> Bool = { $0 == " " || $0 == "\t" }
            var rest = Substring(line)
            indent = String(rest.prefix(while: isBlank))
            rest = rest.dropFirst(indent.count)
            leading = rest.hasPrefix("|")
            if leading { rest = rest.dropFirst() }
            let spaces = rest.reversed().prefix(while: isBlank).count
            var body = rest.dropLast(spaces)
            trailing = body.hasSuffix("|") && body.dropLast().reversed().prefix(while: { $0 == "\\" }).count % 2 == 0
            if trailing {
                body = body.dropLast()
                tail = String(rest.suffix(spaces))
            } else {
                body = rest
                tail = ""
            }
            cells = []
            var raw = ""
            var run = 0
            for ch in body {
                if ch == "\\" {
                    run += 1
                } else if ch == "|", run % 2 == 0 {
                    cells.append(raw)
                    raw = ""
                    run = 0
                    continue
                } else {
                    run = 0
                }
                raw.append(ch)
            }
            cells.append(raw)
        }

        var text: String {
            indent + (leading ? "|" : "") + cells.joined(separator: "|") + (trailing ? "|" : "") + tail
        }
    }
}
