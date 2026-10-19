//
//  NativeTextView+TableGrid.swift
//  MarkdownEngine
//
//  Fork: the live table grids (`TableGridView`) over the document's tables. Each sits in the wide-table scroll
//  view where its table's first line is, keyed by the table's ordinal in the document. A table's source lines stay in
//  the text, hidden; an edit is one splice of them, registered as one undo step.
//

#if os(macOS)
import AppKit

extension NativeTextView {

    /// The grid of the document's `ordinal`th table.
    func tableGrid(ordinal: Int) -> TableGridView? {
        wideTableOverlays[ordinal]?.documentView as? TableGridView
    }

    /// The source lines of the `ordinal`th table.
    func tableRange(ordinal: Int) -> NSRange? {
        guard let coordinator = delegate as? NativeTextViewCoordinator else { return nil }
        let tokens = coordinator.parsedDocument(for: string).tableTokens
        guard tokens.indices.contains(ordinal) else { return nil }
        // An indented table's lines start at the line start, so its indentation is rewritten with it.
        var range = tokens[ordinal].range
        let lineStart = (string as NSString).lineRange(for: NSRange(location: range.location, length: 0)).location
        if lineStart < range.location { range = NSRange(location: lineStart, length: NSMaxRange(range) - lineStart) }
        return range
    }

    /// Replaces table lines as an edit the editor's input handling leaves alone and the undo manager doesn't record
    /// (`registerTableEdit` does).
    func replaceTableText(_ range: NSRange, with text: String) {
        guard let coordinator = delegate as? NativeTextViewCoordinator, NSMaxRange(range) <= (string as NSString).length
        else { return }
        let manager = undoManager
        let previous = selectedRange()
        manager?.disableUndoRegistration()
        coordinator.isProgrammaticEdit = true
        isEditingTableText = true
        defer {
            isEditingTableText = false
            coordinator.isProgrammaticEdit = false
            manager?.enableUndoRegistration()
        }
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        // The edit moves the text view's own selection (it was at, in or after the table): leave it where it was, or
        // off the source, so no selection change reads it as a caret landing in a cell.
        let replaced = NSRange(location: range.location, length: (text as NSString).length)
        let length = (string as NSString).length
        let parked: Int
        if NSMaxRange(previous) <= range.location {
            parked = previous.location
        } else if previous.location > NSMaxRange(range) {
            parked = previous.location + replaced.length - range.length
        } else if NSMaxRange(replaced) + 1 <= length {
            parked = NSMaxRange(replaced) + 1
        } else {
            parked = max(range.location - 1, 0)
        }
        setSelectedRange(NSRange(location: min(parked, length), length: 0))
    }

    func registerTableEdit(_ edit: TableEdit) {
        undoManager?.registerUndo(withTarget: self) { $0.applyTableEdit(edit, forward: false) }
        undoManager?.setActionName(edit.actionName)
    }

    /// Undo (`forward` false) or redo of a table edit: restores the lines and the cell's caret.
    func applyTableEdit(_ edit: TableEdit, forward: Bool) {
        coalescingTableEdit = nil
        let (replaced, text) = forward ? (edit.before, edit.after) : (edit.after, edit.before)
        replaceTableText(NSRange(location: edit.location, length: (replaced as NSString).length), with: text)
        undoManager?.registerUndo(withTarget: self) { $0.applyTableEdit(edit, forward: !forward) }
        undoManager?.setActionName(edit.actionName)
        if let focus = forward ? edit.afterFocus : edit.beforeFocus {
            tableGrid(ordinal: edit.ordinal)?.focus(row: focus.row, column: focus.column, selection: focus.selection)
        }
    }

    /// Creates, positions and drops the grids to match the document's tables, and lets each size its cells. A grid
    /// whose measured height differs from the space the styler reserved has the table restyled with the measure.
    func performTableGridUpdate() {
        guard !isUpdatingTableGrids else { return }
        isUpdatingTableGrids = true
        defer { isUpdatingTableGrids = false }
        for _ in 0..<3 {
            guard let mismatched = reconcileTableGrids() else { return }
            guard !mismatched.isEmpty, let coordinator = delegate as? NativeTextViewCoordinator else { return }
            let parsed = coordinator.parsedDocument(for: string)
            coordinator.restyleTextView(self, paragraphCandidates: mismatched, tokens: parsed.tokens,
                                        classified: parsed.classified, blocks: parsed.blocks)
        }
    }

    /// One pass; the paragraphs to restyle, or nil when there is nothing to reconcile.
    private func reconcileTableGrids() -> [NSRange]? {
        guard let storage = textStorage, let bridge = layoutBridge, let container = bridge.firstTextContainer,
              let coordinator = delegate as? NativeTextViewCoordinator else {
            removeAllWideTableOverlays()
            return nil
        }
        let containerWidth = container.size.width
        guard containerWidth.isFinite, containerWidth > 0 else { return nil }
        let tokens = coordinator.parsedDocument(for: string).tableTokens
        guard !tokens.isEmpty else {
            removeAllWideTableOverlays()
            return nil
        }
        let breakout = configuration.readingWidth != nil
        let host: NSView = breakout ? (superview ?? self) : self
        let viewWidth = host.bounds.width
        let text = string as NSString
        let strip = MarkdownTextLayoutFragment.scrollableBlockScrollerStrip

        var seen: Set<Int> = []
        var mismatched: [NSRange] = []
        for (ordinal, token) in tokens.enumerated() {
            guard NSMaxRange(token.range) <= storage.length,
                  let table = MarkdownStyler.tableMeta(for: text.substring(with: token.range)).parsed else { continue }
            var anchor: NSRange?
            storage.enumerateAttribute(.scrollableBlockSourceID, in: token.range) { value, range, stop in
                if value is Int { anchor = range; stop.pointee = true }
            }
            guard let anchor else { continue }
            // Only the text up to the table's first line needs laying out to place it.
            bridge.ensureLayout(forCharacterRange: anchor)
            let anchorRect = bridge.boundingRect(forCharacterRange: anchor, in: container)
            guard !anchorRect.isEmpty else { continue }
            seen.insert(ordinal)

            let overlay: WideTableOverlay
            let grid: TableGridView
            if let existing = wideTableOverlays[ordinal], let existingGrid = existing.documentView as? TableGridView {
                (overlay, grid) = (existing, existingGrid)
            } else {
                wideTableOverlays[ordinal]?.removeFromSuperview()
                grid = TableGridView(host: self, ordinal: ordinal, table: table)
                overlay = WideTableOverlay(sourceID: ordinal, grid: grid, ownerTextView: self)
                host.addSubview(overlay)
                wideTableOverlays[ordinal] = overlay
                if let saved = tableHorizontalScrollOffsets[ordinal], saved > 0 { overlay.horizontalOffset = saved }
            }
            overlay.anchorTextLocation = token.range.location
            grid.ordinal = ordinal
            let columnLeft = (breakout ? frame.origin.x : 0) + textContainerOrigin.x + anchorRect.minX
            // The table grows with its content up to the editor's width: the text column's, or all of it in a reading
            // column, where the table starts at the column's left.
            let available = breakout ? max(containerWidth, viewWidth - columnLeft) : containerWidth
            grid.update(table: table, availableWidth: available)

            let isWide = grid.layout.size.width - available > 0.5
            let gridHeight = grid.layout.size.height
            let (gutter, topMargin) = (TableGridView.gutter, TableGridView.topMargin)
            let reservedHeight = gridHeight + (isWide ? strip : 0)
            let totalHeight = reservedHeight + topMargin
            let reserved = storage.attribute(.scrollableBlockTotalHeight, at: anchor.location, effectiveRange: nil) as? CGFloat
            if reserved.map({ abs($0 - reservedHeight) > 0.5 }) ?? true {
                tableGridHeights[ordinal] = reservedHeight
                mismatched.append(text.paragraphRange(for: token.range))
            }

            let breakoutTop = frame.origin.y + textContainerOrigin.y + anchorRect.minY
            // The overlay reaches into the gutter left of the table and the margin above it, where the grips are.
            let overlayFrame: NSRect = breakout
                ? NSRect(x: 0, y: breakoutTop - topMargin, width: viewWidth, height: totalHeight)
                : NSRect(x: columnLeft - gutter, y: textContainerOrigin.y + anchorRect.minY - topMargin,
                         width: containerWidth + gutter, height: totalHeight)
            if !overlay.frame.equalTo(overlayFrame) {
                host.setNeedsDisplay(overlay.frame)
                overlay.frame = overlayFrame
                host.setNeedsDisplay(overlayFrame)
            }
            overlay.leftContentInset = breakout ? max(0, columnLeft - gutter) : 0
        }
        for (id, overlay) in wideTableOverlays where !seen.contains(id) {
            host.setNeedsDisplay(overlay.frame)
            overlay.removeFromSuperview()
            wideTableOverlays.removeValue(forKey: id)
        }
        return mismatched
    }

    /// Shows the grips of the row and column under the pointer, from the text view's own mouse-moved events (they
    /// reach it through the grids' overlays). True, with an open hand set, when the pointer is over a grip.
    func updateTableGridHover(for event: NSEvent) -> Bool {
        guard configuration.liveTables, !wideTableOverlays.isEmpty else { return false }
        var overGrip = false
        for overlay in wideTableOverlays.values {
            guard let grid = overlay.documentView as? TableGridView, overlay.superview != nil else { continue }
            let inside = overlay.bounds.contains(overlay.convert(event.locationInWindow, from: nil))
            let point = grid.convert(event.locationInWindow, from: nil)
            grid.updateHover(atViewPoint: inside ? point : nil)
            if inside, grid.handle(at: point) != nil { overGrip = true }
        }
        if overGrip { NSCursor.openHand.set() }
        return overGrip
    }

    func tableStartLocation(_ range: NSRange) -> Int { tableStart(range).location }

    /// The start of a table's first line, after its indentation.
    private func tableStart(_ range: NSRange) -> (location: Int, indent: String) {
        let text = string as NSString
        var end = range.location
        while end < NSMaxRange(range), [0x20, 0x09].contains(text.character(at: end)) { end += 1 }
        return (end, text.substring(with: NSRange(location: range.location, length: end - range.location)))
    }

    /// With live tables, a user edit never lands in a table's hidden source. Typing at a table's start goes above it
    /// (a newline there just adds a blank line); any other edit that is inside the lines or touches them without
    /// containing the whole table is refused, and the cell at that spot takes the keyboard. False refuses the edit.
    func allowsEdit(of range: NSRange, replacement: String) -> Bool {
        guard configuration.liveTables, !hidesSyntaxUnlessFocused, !isEditingTableText, !wideTableOverlays.isEmpty,
              let coordinator = delegate as? NativeTextViewCoordinator, !coordinator.isProgrammaticEdit,
              undoManager?.isUndoing != true, undoManager?.isRedoing != true else { return true }
        let isLineBreak = replacement.first.map { $0 == "\n" || $0 == "\r" } ?? false
        for ordinal in coordinator.parsedDocument(for: string).tableTokens.indices {
            guard let zone = tableRange(ordinal: ordinal), NSMaxRange(range) >= zone.location, range.location <= NSMaxRange(zone)
            else { continue }
            // A range around the whole table is an ordinary edit.
            if range.location <= zone.location, NSMaxRange(range) >= NSMaxRange(zone), range.length > 0 { continue }
            let start = tableStart(zone)
            if range.length == 0, range.location == zone.location || range.location == start.location {
                if isLineBreak { return true }
                guard !replacement.isEmpty else { return true }
                // Typed or pasted at the table's start: it goes on a new line above, indented as the table is.
                MarkdownLists.performEdit(self, replace: NSRange(location: start.location, length: 0),
                                          with: replacement + "\n" + start.indent)
                undoManager?.setActionName("Typing")
                setSelectedRange(NSRange(location: start.location + (replacement as NSString).length, length: 0))
                return false
            }
            if range.length == 0, range.location == NSMaxRange(zone), isLineBreak { return true }
            focusTableCell(ordinal: ordinal, selection: NSRange(location: min(max(range.location, zone.location), NSMaxRange(zone)), length: 0))
            return false
        }
        return true
    }

    /// The caret leaves a table's grid for the line above or below it.
    func leaveTable(ordinal: Int, above: Bool) {
        guard let range = tableRange(ordinal: ordinal) else { return }
        let length = (string as NSString).length
        let target: Int
        // Past a document edge there is no line to go to: a line break there makes one, as one undo step.
        if above, range.location == 0 {
            MarkdownLists.performEdit(self, replace: NSRange(location: 0, length: 0), with: "\n")
            undoManager?.setActionName("Insert Line")
            target = 0
        } else if !above, NSMaxRange(range) >= length {
            MarkdownLists.performEdit(self, replace: NSRange(location: length, length: 0), with: "\n")
            undoManager?.setActionName("Insert Line")
            target = (string as NSString).length
        } else {
            target = above ? range.location - 1 : NSMaxRange(range) + 1
        }
        // The caret moves off the source before the text view takes the keyboard, which would send it to a cell.
        setSelectedRange(NSRange(location: target, length: 0))
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: target, length: 0))
    }

    /// A selection that lands in a table's source (Find, the slash menu's Table, a click that reaches the text) gives
    /// the keyboard to the cell it falls in, and the text view's own caret moves off the source.
    func focusTableCell(ordinal: Int, selection: NSRange) {
        performTableGridUpdate()
        guard let range = tableRange(ordinal: ordinal), let grid = tableGrid(ordinal: ordinal) else { return }
        let source = (string as NSString).substring(with: range)
        guard let cell = MarkdownTable.cellLocation(in: source, offset: selection.location - range.location) else { return }
        let row = min(cell.row, grid.table.rowCount - 1)
        let column = min(cell.column, grid.table.columnCount - 1)
        let length = (grid.table.cell(row: row, column: column) as NSString).length
        var mapped = NSRange(location: min(cell.offset, length), length: 0)
        if selection.length > 0, let end = MarkdownTable.cellLocation(in: source, offset: NSMaxRange(selection) - range.location),
           end.row == cell.row, end.column == cell.column {
            mapped.length = min(end.offset, length) - mapped.location
        }
        let outside = NSMaxRange(range) + 1 <= (string as NSString).length ? NSMaxRange(range) + 1 : range.location - 1
        if outside >= 0 { setSelectedRange(NSRange(location: outside, length: 0)) }
        grid.focus(row: row, column: column, selection: mapped)
    }

    /// ↓ (`above`) on the line straight above a table, or ↑ on the one below it, enters its first or last row.
    /// False when the caret isn't there.
    func enterTable(from selector: Selector) -> Bool {
        let down = selector == #selector(NSResponder.moveDown(_:))
        guard down || selector == #selector(NSResponder.moveUp(_:)), selectedRange().length == 0,
              let grid = firstTableGrid(adjacentToCaretMovingDown: down) else { return false }
        grid.focus(row: down ? 0 : grid.table.rowCount - 1, column: 0, selection: NSRange(location: 0, length: 0))
        return true
    }

    private func firstTableGrid(adjacentToCaretMovingDown down: Bool) -> TableGridView? {
        guard let coordinator else { return nil }
        let text = string as NSString
        let caret = min(selectedRange().location, text.length)
        let line = text.lineRange(for: NSRange(location: caret, length: 0))
        for (ordinal, token) in coordinator.parsedDocument(for: string).tableTokens.enumerated() {
            let touches = down ? NSMaxRange(line) == token.range.location : line.location == NSMaxRange(token.range) + 1
            if touches { return tableGrid(ordinal: ordinal) }
        }
        return nil
    }

    private var coordinator: NativeTextViewCoordinator? { delegate as? NativeTextViewCoordinator }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, hidesSyntaxUnlessFocused {
            hasEditingFocus = true
            (delegate as? NativeTextViewCoordinator)?.editingFocusDidChange(in: self)
            if let cell = tableCell { cell.grid?.cellDidBecomeFocused(cell) }
        } else if accepted, configuration.liveTables, !wideTableOverlays.isEmpty,
                  let coordinator = delegate as? NativeTextViewCoordinator {
            // The caret was left in a table's source: the cell it falls in takes the keyboard. A caret at the table's
            // start is the spot above it, which typing handles.
            let selection = selectedRange()
            guard !isEditingTableText else { return accepted }
            for ordinal in coordinator.parsedDocument(for: string).tableTokens.indices {
                guard let zone = tableRange(ordinal: ordinal), selection.location >= zone.location,
                      NSMaxRange(selection) <= NSMaxRange(zone) else { continue }
                if selection.length == 0, selection.location == zone.location || selection.location == tableStart(zone).location { break }
                focusTableCell(ordinal: ordinal, selection: selection)
                break
            }
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted, hidesSyntaxUnlessFocused {
            hasEditingFocus = false
            (delegate as? NativeTextViewCoordinator)?.editingFocusDidChange(in: self)
            if let cell = tableCell { cell.grid?.cellDidResignFocus(cell) }
        }
        return accepted
    }
}
#endif
