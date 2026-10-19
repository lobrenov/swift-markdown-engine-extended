//
//  TableGridView.swift
//  MarkdownEngine
//
//  Fork: a table as a grid of cell editors over its hidden source lines, on the Mac. The cells are the
//  editors; the grid draws the header fill and the borders, sizes each row to its tallest cell, and writes every
//  change back as one splice of the table's lines, padded (`MarkdownTable.markdown`).
//

#if os(macOS)
import AppKit

/// A cell and the selection in it, to restore on undo and redo.
struct CellFocus: Equatable {
    var row: Int
    var column: Int
    var selection: NSRange
}

/// One undoable change of a table's lines: typing coalesces into one, each structural change is its own.
final class TableEdit {
    let ordinal: Int
    let location: Int
    let before: String
    var after: String
    let beforeFocus: CellFocus?
    var afterFocus: CellFocus?
    let actionName: String

    init(ordinal: Int, location: Int, before: String, after: String, beforeFocus: CellFocus?, afterFocus: CellFocus?,
         actionName: String) {
        self.ordinal = ordinal
        self.location = location
        self.before = before
        self.after = after
        self.beforeFocus = beforeFocus
        self.afterFocus = afterFocus
        self.actionName = actionName
    }
}

/// A row or a column of a table, as its grip selects it.
enum TableHandle: Equatable {
    case row(Int)
    case column(Int)
}

final class TableGridView: NSView {
    weak var host: NativeTextView?
    var ordinal: Int
    private(set) var table: MarkdownTable
    private(set) var layout: MarkdownStyler.TableLayout
    private(set) var editors: [[TableCellEditor]] = []
    private var isUpdating = false
    /// The row and column under the pointer, which show their grips.
    var hoverRow: Int?
    var hoverColumn: Int?
    /// The row or column a click on its grip selected.
    var selectedHandle: TableHandle?
    /// The grip being pressed, where, and the gap a drag would drop it in.
    var pressedHandle: (handle: TableHandle, start: CGPoint)?
    var dropGap: Int?
    /// The grip whose right-click menu is open: ringed like a selection.
    var menuHandle: TableHandle?
    /// The grip under the pointer, whose ring fades in (`ringHandle` and `ringAlpha` follow it, and fade out after it).
    var gripHover: TableHandle?
    var ringHandle: TableHandle?
    var ringAlpha: CGFloat = 0
    var fadeTimer: Timer?
    static let ringFadeDuration: TimeInterval = 0.15
    /// What the cells were last laid out for; `update` does nothing while it still holds.
    private var appliedSignature: LayoutSignature?
    private var appliedConfig: ConfigSignature?
    /// A change the signature doesn't see (a cell's own edit or focus) moved the cells' heights.
    var needsRelayout = true

    private struct ConfigSignature: Equatable {
        let theme: MarkdownEditorTheme
        let font: String
        let extensions: String
        let wiki: AnyHashable
    }

    private struct LayoutSignature: Equatable {
        let table: MarkdownTable
        let width: CGFloat
        let config: ConfigSignature
    }
    /// Where ⌘C and ⌘X put a selected row or column.
    var pasteboard: NSPasteboard = .general
    /// Where the typing that `coalescingTableEdit` holds last ended, as a location in its cell.
    private var typingEnd: (row: Int, column: Int, location: Int)?

    override var isFlipped: Bool { true }

    /// The room left of the table for the row grips, and above it for the column grips.
    static let gutter: CGFloat = 16
    static let topMargin: CGFloat = 12

    init(host: NativeTextView, ordinal: Int, table: MarkdownTable) {
        self.host = host
        self.ordinal = ordinal
        self.table = table
        layout = MarkdownStyler.TableLayout(columnWidths: [], rowContentHeights: [])
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func editor(row: Int, column: Int) -> TableCellEditor? {
        editors.indices.contains(row) && editors[row].indices.contains(column) ? editors[row][column] : nil
    }

    // MARK: - Layout

    /// Shows `newTable`: adds or drops cells, sets the text of those that differ, and sizes the rows to their
    /// tallest cell. The cell being edited keeps its text and caret.
    func update(table newTable: MarkdownTable, availableWidth: CGFloat) {
        guard let host else { return }
        let config = ConfigSignature(
            theme: host.configuration.theme, font: "\(host.baseFont.fontName)|\(host.baseFont.pointSize)",
            extensions: "\(host.configuration.extensionRegistry.fingerprint)",
            wiki: host.configuration.services.wikiLinks.fingerprint()
        )
        let configChanged = config != appliedConfig
        appliedConfig = config
        let signature = LayoutSignature(table: newTable, width: availableWidth, config: config)
        for row in editors { row.forEach { $0.syncCallbacks(from: host) } }
        if !needsRelayout, signature == appliedSignature { return }
        needsRelayout = false
        appliedSignature = signature
        isUpdating = true
        defer { isUpdating = false }
        table = newTable
        switch selectedHandle {
        case .row(let r)? where r >= newTable.rowCount: selectedHandle = nil
        case .column(let c)? where c >= newTable.columnCount: selectedHandle = nil
        default: break
        }
        resizeEditors(host: host)
        let hostConfiguration = host.configuration
        for (r, row) in editors.enumerated() {
            for (c, editor) in row.enumerated() {
                if configChanged || editor.appliedHeader != (r == 0) { editor.syncConfiguration(from: host) }
                editor.setAlignment(newTable.alignments[c])
                let want = newTable.cell(row: r, column: c)
                if editor.text.trimmingCharacters(in: .whitespaces) != want { editor.setText(want) }
            }
        }
        // The cells' own measures decide the widths: each column as wide as its widest cell, up to the available width.
        let live = MarkdownStyler.LiveCellMetrics(
            natural: { [unowned self] r, c in self.editors[r][c].naturalWidth() },
            height: { [unowned self] r, c, width in self.editors[r][c].contentHeight(width: width) }
        )
        layout = MarkdownStyler.tableLayout(
            newTable, baseFont: host.baseFont, theme: hostConfiguration.theme,
            codeBackgroundColor: hostConfiguration.services.syntaxHighlighter.backgroundColor(),
            latex: hostConfiguration.services.latex, availableWidth: availableWidth,
            extensions: hostConfiguration.extensions, live: live
        ).layout
        let (widths, heights) = (layout.columnWidths, layout.rowContentHeights)
        for row in editors { for editor in row { editor.setContentWidth(widths[editor.column]) } }
        let (hPad, vPad) = (MarkdownStyler.TableLayout.cellHPadding, MarkdownStyler.TableLayout.cellVPadding)
        for (r, row) in editors.enumerated() {
            for (c, editor) in row.enumerated() {
                editor.textView.frame = CGRect(x: Self.gutter + layout.columnLeft[c], y: Self.topMargin + layout.rowTop[r],
                                               width: widths[c] + 2 * hPad, height: heights[r] + 2 * vPad)
            }
        }
        let size = CGSize(width: Self.gutter + layout.size.width, height: Self.topMargin + layout.size.height)
        if frame.size != size { setFrameSize(size) }
        needsDisplay = true
    }

    private func resizeEditors(host: NativeTextView) {
        while editors.count > table.rowCount {
            editors.removeLast().forEach { $0.textView.removeFromSuperview() }
        }
        for r in 0..<table.rowCount {
            if r >= editors.count { editors.append([]) }
            while editors[r].count > table.columnCount { editors[r].removeLast().textView.removeFromSuperview() }
            while editors[r].count < table.columnCount {
                let editor = TableCellEditor(host: host, row: r, column: editors[r].count)
                editor.grid = self
                editor.coordinator.onDisplayTextChange = { [weak self, weak editor] text in
                    guard let self, let editor else { return }
                    self.cellDidChange(editor, text: text)
                }
                editor.coordinator.onSelectionChange = { [weak self, weak editor] in
                    guard let self, let editor, editor.grid === self, self.host?.isEditingTableText != true else { return }
                    self.cellLayoutMayHaveChanged(editor)
                }
                addSubview(editor.textView)
                editors[r].append(editor)
            }
            for (c, editor) in editors[r].enumerated() { (editor.row, editor.column) = (r, c) }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let host, layout.columnWidths.isEmpty == false else { return }
        NSGraphicsContext.current?.saveGraphicsState()
        defer { drawHandles(host: host) }
        NSGraphicsContext.current?.cgContext.translateBy(x: Self.gutter, y: Self.topMargin)
        defer { NSGraphicsContext.current?.restoreGraphicsState() }
        let border = MarkdownStyler.TableLayout.borderWidth
        let vPad = MarkdownStyler.TableLayout.cellVPadding
        let muted = host.configuration.theme.mutedText.resolved(under: effectiveAppearance)
        muted.withAlphaComponent(0.08).setFill()
        NSBezierPath(rect: CGRect(x: border, y: border, width: layout.size.width - 2 * border,
                                  height: layout.rowContentHeights[0] + 2 * vPad)).fill()
        muted.withAlphaComponent(0.5).setStroke()
        let outer = NSBezierPath(rect: CGRect(x: border / 2, y: border / 2, width: layout.size.width - border,
                                              height: layout.size.height - border))
        outer.lineWidth = border
        outer.stroke()
        let separators = NSBezierPath()
        separators.lineWidth = border
        for i in 1..<max(1, layout.columnWidths.count) {
            let x = layout.columnLeft[i] - border / 2
            separators.move(to: CGPoint(x: x, y: 0))
            separators.line(to: CGPoint(x: x, y: layout.size.height))
        }
        for i in 1..<max(1, layout.rowContentHeights.count) {
            let y = layout.rowTop[i] - border / 2
            separators.move(to: CGPoint(x: 0, y: y))
            separators.line(to: CGPoint(x: layout.size.width, y: y))
        }
        separators.stroke()
    }

    // MARK: - Focus

    /// Gives the keyboard to a cell, with the caret at the end of its text unless `selection` says otherwise.
    func focus(row: Int, column: Int, selection: NSRange? = nil) {
        guard let editor = editor(row: row, column: column) else { return }
        window?.makeFirstResponder(editor.textView)
        let length = (editor.textView.string as NSString).length
        let wanted = selection ?? NSRange(location: length, length: 0)
        let location = min(wanted.location, length)
        editor.textView.setSelectedRange(NSRange(location: location, length: min(wanted.length, length - location)))
    }

    var focusedCell: CellFocus? {
        for row in editors {
            for editor in row where editor.textView.hasEditingFocus {
                return CellFocus(row: editor.row, column: editor.column, selection: editor.textView.selectedRange())
            }
        }
        return nil
    }

    func cellDidBecomeFocused(_ editor: TableCellEditor) {
        host?.focusedTableCell = editor
        host?.coalescingTableEdit = nil
        cellLayoutMayHaveChanged(editor)
    }

    func cellDidResignFocus(_ editor: TableCellEditor) {
        if host?.focusedTableCell === editor { host?.focusedTableCell = nil }
        host?.coalescingTableEdit = nil
        cellLayoutMayHaveChanged(editor)
    }

    /// Showing or hiding a cell's syntax (focus, the caret crossing a span) can change its height: lay the table out
    /// again when it did.
    func cellLayoutMayHaveChanged(_ editor: TableCellEditor) {
        guard !isUpdating, editor.row < layout.rowContentHeights.count, editor.column < layout.columnWidths.count else { return }
        let needed = editors[editor.row].map { $0.contentHeight(width: layout.columnWidths[$0.column]) }.max() ?? 0
        guard abs(needed - layout.rowContentHeights[editor.row]) > 0.5 else { return }
        needsRelayout = true
        host?.updateWideTableOverlays(immediately: true)
    }

    // MARK: - Keys

    private static let listLine = try! NSRegularExpression(pattern: #"^[ \t]*(?:>[ \t]*)*(?:(?:\d+[.)])|[-•*+])[ \t]+"#)

    /// Tab, Shift-Tab and the arrows in a cell, per the table's keys. False leaves the key to the editor.
    func handleCommand(_ selector: Selector, from editor: TableCellEditor) -> Bool {
        let textView = editor.textView
        let selection = textView.selectedRange()
        let length = (textView.string as NSString).length
        switch selector {
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            if isOnListLine(textView) { return false }
            if selector == #selector(NSResponder.insertTab(_:)) { tabForward(from: editor) } else { tabBackward(from: editor) }
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard selection.length == 0, isOnEdgeLine(textView, first: true) else { return false }
            moveVertically(from: editor, up: true)
            return true
        case #selector(NSResponder.moveDown(_:)):
            guard selection.length == 0, isOnEdgeLine(textView, first: false) else { return false }
            moveVertically(from: editor, up: false)
            return true
        case #selector(NSResponder.moveLeft(_:)):
            guard selection == NSRange(location: 0, length: 0) else { return false }
            if let previous = neighbour(of: editor, by: -1) {
                focus(row: previous.row, column: previous.column)
            } else {
                host?.leaveTable(ordinal: ordinal, above: true)
            }
            return true
        case #selector(NSResponder.moveRight(_:)):
            guard selection == NSRange(location: length, length: 0) else { return false }
            if let next = neighbour(of: editor, by: 1) {
                focus(row: next.row, column: next.column, selection: NSRange(location: 0, length: 0))
            } else {
                host?.leaveTable(ordinal: ordinal, above: false)
            }
            return true
        default:
            return false
        }
    }

    private func isOnListLine(_ textView: NativeTextView) -> Bool {
        let text = textView.string as NSString
        let line = text.substring(with: text.lineRange(for: NSRange(location: min(textView.selectedRange().location, text.length), length: 0)))
        return Self.listLine.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    /// Whether the caret is on the cell's first (or last) line as laid out, so wrapped lines count.
    private func isOnEdgeLine(_ textView: NativeTextView, first: Bool) -> Bool {
        let length = (textView.string as NSString).length
        let edge = NSRange(location: first ? 0 : length, length: 0)
        let caret = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
        let reference = textView.firstRect(forCharacterRange: edge, actualRange: nil)
        return abs(caret.midY - reference.midY) < 2
    }

    private func neighbour(of editor: TableCellEditor, by step: Int) -> (row: Int, column: Int)? {
        let index = editor.row * table.columnCount + editor.column + step
        guard index >= 0, index < table.rowCount * table.columnCount else { return nil }
        return (index / table.columnCount, index % table.columnCount)
    }

    /// Tab: the next cell; on the last, a new row with the caret in its first cell.
    func tabForward(from editor: TableCellEditor) {
        if let next = neighbour(of: editor, by: 1) {
            focus(row: next.row, column: next.column)
        } else {
            var newTable = table
            newTable.insertRow(at: newTable.rowCount)
            host?.coalescingTableEdit = nil
            commit(newTable, actionName: "Add Row", beforeFocus: focusedCell,
                   afterFocus: CellFocus(row: newTable.rowCount - 1, column: 0, selection: NSRange(location: 0, length: 0)))
            focus(row: newTable.rowCount - 1, column: 0)
        }
    }

    /// Shift-Tab: the previous cell; nothing on the first.
    func tabBackward(from editor: TableCellEditor) {
        if let previous = neighbour(of: editor, by: -1) { focus(row: previous.row, column: previous.column) }
    }

    /// ↑ on a cell's first line, ↓ on its last: the cell above or below, with the caret at the same x; past the header
    /// or the last row, out of the table.
    private func moveVertically(from editor: TableCellEditor, up: Bool) {
        let row = editor.row + (up ? -1 : 1)
        guard let target = self.editor(row: row, column: editor.column) else {
            host?.leaveTable(ordinal: ordinal, above: up)
            return
        }
        let caret = editor.textView.firstRect(forCharacterRange: editor.textView.selectedRange(), actualRange: nil)
        let inWindow = window?.convertFromScreen(caret) ?? caret
        let x = target.textView.convert(inWindow.origin, from: nil).x
        let vPad = MarkdownStyler.TableLayout.cellVPadding
        let y = up ? target.textView.bounds.height - vPad - 2 : vPad + 2
        window?.makeFirstResponder(target.textView)
        let location = target.textView.characterIndexForInsertion(at: CGPoint(x: x, y: y))
        target.textView.setSelectedRange(NSRange(location: location, length: 0))
    }

    // MARK: - Writing

    /// A cell's text changed by typing or a command inside the cell.
    private func cellDidChange(_ editor: TableCellEditor, text: String) {
        guard !isUpdating, let host else { return }
        needsRelayout = true
        let old = table.cell(row: editor.row, column: editor.column)
        var newTable = table
        newTable.setCell(row: editor.row, column: editor.column, to: text)
        // The edit's span in the cell, as a plain-text diff.
        let (oldNS, newNS) = (old as NSString, text as NSString)
        var prefix = 0
        while prefix < min(oldNS.length, newNS.length), oldNS.character(at: prefix) == newNS.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < min(oldNS.length, newNS.length) - prefix,
              oldNS.character(at: oldNS.length - 1 - suffix) == newNS.character(at: newNS.length - 1 - suffix) { suffix += 1 }
        let removed = oldNS.length - prefix - suffix
        let inserted = newNS.length - prefix - suffix
        let after = CellFocus(row: editor.row, column: editor.column, selection: editor.textView.selectedRange())
        let before = CellFocus(row: editor.row, column: editor.column,
                               selection: inserted == 0 ? NSRange(location: prefix + removed, length: 0)
                                                        : NSRange(location: prefix, length: removed))
        let continues = host.coalescingTableEdit != nil && typingEnd.map {
            $0.row == editor.row && $0.column == editor.column
                && (removed == 0 ? prefix == $0.location : prefix + removed == $0.location)
        } == true
        commit(newTable, actionName: "Typing", beforeFocus: before, afterFocus: after, coalesces: continues)
        typingEnd = (editor.row, editor.column, prefix + inserted)
    }

    /// Writes `newTable` over the table's lines as one splice and registers its undo. With `coalesces`, a typing
    /// edit continues the one on top of the undo stack instead.
    func commit(_ newTable: MarkdownTable, actionName: String, beforeFocus: CellFocus?, afterFocus: CellFocus?,
                coalesces: Bool = false) {
        guard let host, let range = host.tableRange(ordinal: ordinal) else { return }
        let old = (host.string as NSString).substring(with: range)
        let markdown = newTable.markdown
        table = newTable
        needsRelayout = true
        guard markdown != old else {
            host.updateWideTableOverlays(immediately: true)
            return
        }
        host.replaceTableText(range, with: markdown)
        if coalesces, let edit = host.coalescingTableEdit {
            edit.after = markdown
            edit.afterFocus = afterFocus
            return
        }
        let edit = TableEdit(ordinal: ordinal, location: range.location, before: old, after: markdown,
                             beforeFocus: beforeFocus, afterFocus: afterFocus, actionName: actionName)
        host.registerTableEdit(edit)
        host.coalescingTableEdit = actionName == "Typing" ? edit : nil
    }
}
#endif
