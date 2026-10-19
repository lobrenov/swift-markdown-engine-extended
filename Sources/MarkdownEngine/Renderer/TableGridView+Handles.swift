//
//  TableGridView+Handles.swift
//  MarkdownEngine
//
//  Fork: a live table's grips. A hovered row shows a grip in the gutter left of it, a hovered column one above
//  its header cell. A click on a grip selects the row or column with a ring; ⌘C and ⌘X copy it as a table, ⌫ deletes
//  it, esc or a click elsewhere clears it. Dragging a grip moves it to the drop line; the header stays first.
//

#if os(macOS)
import AppKit

extension TableGridView {

    private var accent: NSColor { host?.configuration.tableAccent ?? host?.configuration.theme.link ?? .controlAccentColor }
    private var muted: NSColor { (host?.configuration.theme.mutedText ?? .secondaryLabelColor).resolved(under: effectiveAppearance) }
    private var border: CGFloat { MarkdownStyler.TableLayout.borderWidth }

    // MARK: - Geometry

    /// The index of the band of `edges` (the leading edge of each item, then the end) that holds `value`.
    private func band(_ value: CGFloat, edges: [CGFloat], ends: [CGFloat]) -> Int? {
        for i in edges.indices where value >= edges[i] - border && value < ends[i] + border { return i }
        return nil
    }

    private var rowEnds: [CGFloat] {
        layout.rowContentHeights.indices.map { layout.rowTop[$0] + layout.rowContentHeights[$0] + 2 * MarkdownStyler.TableLayout.cellVPadding }
    }

    private var columnEnds: [CGFloat] {
        layout.columnWidths.indices.map { layout.columnLeft[$0] + layout.columnWidths[$0] + 2 * MarkdownStyler.TableLayout.cellHPadding }
    }

    private func contentPoint(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - Self.gutter, y: point.y - Self.topMargin) }

    private func rowBand(_ y: CGFloat) -> Int? { band(y, edges: Array(layout.rowTop.dropLast()), ends: rowEnds) }
    private func columnBand(_ x: CGFloat) -> Int? { band(x, edges: Array(layout.columnLeft.dropLast()), ends: columnEnds) }

    /// The grip at `point` (in this view's coordinates), if it is in a grip's strip.
    func handle(at point: CGPoint) -> TableHandle? {
        let p = contentPoint(point)
        if point.x >= 0, point.x < Self.gutter, let row = rowBand(p.y) { return .row(row) }
        if point.y >= 0, point.y < Self.topMargin, let column = columnBand(p.x) { return .column(column) }
        return nil
    }

    // MARK: - Drawing

    func drawHandles(host: NativeTextView) {
        guard layout.columnWidths.isEmpty == false else { return }
        let gridRect = CGRect(x: Self.gutter, y: Self.topMargin, width: layout.size.width, height: layout.size.height)
        // The hovered grip's ring fades; a selected or menu-open handle's is at full strength.
        var rings: [(TableHandle, CGFloat)] = [selectedHandle, menuHandle].compactMap { $0 }.map { ($0, 1) }
        if let ringHandle, ringAlpha > 0, !rings.contains(where: { $0.0 == ringHandle }) { rings.append((ringHandle, ringAlpha)) }
        for (ringed, alpha) in rings {
            guard let rect = bandRect(ringed) else { continue }
            accent.withAlphaComponent(alpha).setStroke()
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2)
            ring.lineWidth = 2
            ring.stroke()
        }
        var grips: [TableHandle] = []
        if let hoverRow { grips.append(.row(hoverRow)) }
        if let hoverColumn { grips.append(.column(hoverColumn)) }
        for shown in [selectedHandle, menuHandle].compactMap({ $0 }) where !grips.contains(shown) { grips.append(shown) }
        for handle in grips { drawGrip(handle, selected: handle == selectedHandle) }
        if let dropGap, let pressedHandle, isDragging {
            accent.setFill()
            switch pressedHandle.handle {
            case .row:
                let y = Self.topMargin + layout.rowTop[dropGap] - border / 2
                NSBezierPath(rect: CGRect(x: gridRect.minX, y: y - 1, width: gridRect.width, height: 2)).fill()
            case .column:
                let x = Self.gutter + layout.columnLeft[dropGap] - border / 2
                NSBezierPath(rect: CGRect(x: x - 1, y: gridRect.minY, width: 2, height: gridRect.height)).fill()
            }
        }
    }

    /// The row's or column's rect, borders included, in this view's coordinates.
    private func bandRect(_ handle: TableHandle) -> CGRect? {
        switch handle {
        case .row(let r):
            guard r < layout.rowContentHeights.count else { return nil }
            return CGRect(x: Self.gutter, y: Self.topMargin + layout.rowTop[r] - border, width: layout.size.width,
                          height: rowEnds[r] - layout.rowTop[r] + 2 * border)
        case .column(let c):
            guard c < layout.columnWidths.count else { return nil }
            return CGRect(x: Self.gutter + layout.columnLeft[c] - border, y: Self.topMargin,
                          width: columnEnds[c] - layout.columnLeft[c] + 2 * border, height: layout.size.height)
        }
    }

    /// Six dots: two columns of three beside a row, two rows of three above a column.
    private func drawGrip(_ handle: TableHandle, selected: Bool) {
        guard let rect = bandRect(handle) else { return }
        let (dot, gap): (CGFloat, CGFloat) = (2, 2.5)
        let center: CGPoint
        let (across, along): (Int, Int)
        switch handle {
        case .row:
            center = CGPoint(x: Self.gutter / 2, y: rect.midY)
            (across, along) = (2, 3)
        case .column:
            center = CGPoint(x: rect.midX, y: Self.topMargin / 2)
            (across, along) = (3, 2)
        }
        (selected ? accent : muted).setFill()
        let step = dot + gap
        let width = CGFloat(across) * step - gap, height = CGFloat(along) * step - gap
        for i in 0..<across {
            for j in 0..<along {
                NSBezierPath(ovalIn: CGRect(x: center.x - width / 2 + CGFloat(i) * step, y: center.y - height / 2 + CGFloat(j) * step,
                                            width: dot, height: dot)).fill()
            }
        }
    }

    /// Whether a click at `point` is the grid's: on its grips or anywhere in the table, borders and padding included;
    /// the margins around the grips belong to the text.
    func claims(_ point: CGPoint) -> Bool {
        handle(at: point) != nil
            || CGRect(x: Self.gutter, y: Self.topMargin, width: layout.size.width, height: layout.size.height).contains(point)
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { updateHover(atViewPoint: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { updateHover(atViewPoint: nil) }

    /// Shows the grips of the row and column under `point` (nil: none).
    func updateHover(atViewPoint point: CGPoint?) {
        var row: Int?, column: Int?
        if let point, bounds.contains(point) {
            let p = contentPoint(point)
            row = rowBand(p.y)
            column = columnBand(p.x)
        }
        let grip = point.flatMap { bounds.contains($0) ? handle(at: $0) : nil }
        setGripHover(grip)
        guard row != hoverRow || column != hoverColumn else { return }
        (hoverRow, hoverColumn) = (row, column)
        needsDisplay = true
    }

    /// The ring of the grip under the pointer fades in over `ringFadeDuration`, and out when the pointer leaves it.
    private func setGripHover(_ grip: TableHandle?) {
        guard grip != gripHover else { return }
        gripHover = grip
        if let grip, ringHandle != grip {
            ringHandle = grip
            ringAlpha = 0
        }
        fadeTimer?.invalidate()
        let started = Date()
        let from = ringAlpha
        let target: CGFloat = grip == nil ? 0 : 1
        fadeTimer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                let progress = min(1, Date().timeIntervalSince(started) / Self.ringFadeDuration)
                self.ringAlpha = from + (target - from) * CGFloat(progress)
                self.needsDisplay = true
                if progress >= 1 {
                    timer.invalidate()
                    if target == 0 { self.ringHandle = nil }
                }
            }
        }
        RunLoop.main.add(fadeTimer!, forMode: .common)
    }

    // MARK: - Selecting and dragging

    override var acceptsFirstResponder: Bool { true }

    var isDragging: Bool { dropGap != nil }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let handle = handle(at: point) else { return focusNearestCell(to: point) }
        select(handle)
        // The header row can't be dragged.
        pressedHandle = handle == .row(0) ? nil : (handle, point)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let handle = handle(at: convert(event.locationInWindow, from: nil)) else { return super.rightMouseDown(with: event) }
        showMenu(for: handle)
    }

    /// A click that isn't on a grip or a cell's text view (a border, the padding) focuses the nearest cell, with the
    /// caret at the nearest character, and clears the row or column selection.
    private func focusNearestCell(to point: CGPoint) {
        let cells = editors.flatMap { $0 }
        let nearest = cells.min { distance(from: point, to: $0.textView.frame) < distance(from: point, to: $1.textView.frame) }
        guard let editor = nearest else { return }
        selectedHandle = nil
        needsDisplay = true
        window?.makeFirstResponder(editor.textView)
        let local = editor.textView.convert(point, from: self)
        let clamped = CGPoint(x: min(max(local.x, 0), editor.textView.bounds.width - 1),
                              y: min(max(local.y, 0), editor.textView.bounds.height - 1))
        editor.textView.setSelectedRange(NSRange(location: editor.textView.characterIndexForInsertion(at: clamped), length: 0))
    }

    private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        hypot(max(rect.minX - point.x, 0, point.x - rect.maxX), max(rect.minY - point.y, 0, point.y - rect.maxY))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressedHandle else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - pressedHandle.start.x, point.y - pressedHandle.start.y) > 4 || dropGap != nil else { return }
        NSCursor.closedHand.set()
        let p = contentPoint(point)
        switch pressedHandle.handle {
        case .row:
            let gap = (0..<layout.rowContentHeights.count).filter { p.y > (layout.rowTop[$0] + rowEnds[$0]) / 2 }.count
            dropGap = max(1, gap)
        case .column:
            dropGap = (0..<layout.columnWidths.count).filter { p.x > (layout.columnLeft[$0] + columnEnds[$0]) / 2 }.count
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressedHandle = nil
            dropGap = nil
            needsDisplay = true
            (handle(at: convert(event.locationInWindow, from: nil)) == nil ? NSCursor.arrow : NSCursor.openHand).set()
        }
        guard let pressedHandle, let gap = dropGap else { return }
        move(pressedHandle.handle, toGap: gap)
    }

    /// Selects a row or column and takes the keyboard for ⌘C, ⌘X, ⌫ and esc.
    func select(_ handle: TableHandle?) {
        if let handle { window?.makeFirstResponder(self) }
        selectedHandle = handle
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        selectedHandle = nil
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: deleteSelected()
        case 53: select(nil)
        default: break
        }
    }

    // MARK: - Menu

    /// The grip's right-click menu, sent to the embedder with the grip ringed until it closes.
    func showMenu(for handle: TableHandle) {
        guard let host, let onRightClickMenu = host.onRightClickMenu, let rect = gripRect(handle) else { return }
        menuHandle = handle
        needsDisplay = true
        let anchor = window?.convertToScreen(convert(rect, to: nil)) ?? .zero
        let ordinal = ordinal
        // The menu's actions find the grid again: it may have been rebuilt while the menu was open.
        func grid(_ body: @escaping @MainActor (TableGridView) -> Void) -> @MainActor () -> Void {
            { [weak host] in if let grid = host?.tableGrid(ordinal: ordinal) { body(grid) } }
        }
        let sections: [[RightClickMenuItem]]
        switch handle {
        case .row(let r):
            sections = [[
                RightClickMenuItem("Insert above", symbolName: "arrow.up.to.line", action: grid { $0.insertRow(at: r) }),
                RightClickMenuItem("Insert below", symbolName: "arrow.down.to.line", action: grid { $0.insertRow(at: r + 1) }),
                RightClickMenuItem("Delete row", symbolName: "trash", isDestructive: true, action: grid { $0.deleteRow(r) }),
            ]]
        case .column(let c):
            let current = table.alignments[c]
            func align(_ title: String, _ symbol: String, _ alignment: MarkdownTable.Alignment) -> RightClickMenuItem {
                RightClickMenuItem(title, symbolName: symbol, isChecked: current == alignment,
                                   action: grid { $0.setAlignment(alignment, column: c) })
            }
            sections = [[
                RightClickMenuItem("Insert left", symbolName: "arrow.left.to.line", action: grid { $0.insertColumn(at: c) }),
                RightClickMenuItem("Insert right", symbolName: "arrow.right.to.line", action: grid { $0.insertColumn(at: c + 1) }),
                RightClickMenuItem("Delete column", symbolName: "trash", isDestructive: true, action: grid { $0.deleteColumn(c) }),
            ], [
                align("Align left", "text.alignleft", .left),
                align("Align centre", "text.aligncenter", .center),
                align("Align right", "text.alignright", .right),
            ]]
        }
        onRightClickMenu(RightClickMenuRequest(sections: sections, anchorRect: anchor, close: { [weak host] in
            guard let grid = host?.tableGrid(ordinal: ordinal), grid.menuHandle == handle else { return }
            grid.menuHandle = nil
            grid.needsDisplay = true
        }))
    }

    /// The grip's strip in this view's coordinates.
    private func gripRect(_ handle: TableHandle) -> CGRect? {
        guard let band = bandRect(handle) else { return nil }
        switch handle {
        case .row: return CGRect(x: 0, y: band.minY, width: Self.gutter, height: band.height)
        case .column: return CGRect(x: band.minX, y: 0, width: band.width, height: Self.topMargin)
        }
    }

    // MARK: - Actions

    /// The selected row or column as a markdown table: the header and delimiter rows come with it.
    var selectedMarkdown: String? {
        switch selectedHandle {
        case .row(let r)?:
            return MarkdownTable(header: table.header, alignments: table.alignments,
                                 rows: r == 0 ? [] : [table.rows[r - 1]]).markdown
        case .column(let c)?:
            return MarkdownTable(header: [table.header[c]], alignments: [table.alignments[c]],
                                 rows: table.rows.map { [$0[c]] }).markdown
        case nil:
            return nil
        }
    }

    @objc func copy(_ sender: Any?) {
        guard let markdown = selectedMarkdown, let host else { return }
        MarkdownPasteboardWriter.write(markdown: markdown, to: pasteboard, extensions: host.configuration.extensions,
                                       directives: host.configuration.directives,
                                       directiveSettings: host.configuration.directiveSettings)
    }

    @objc func cut(_ sender: Any?) {
        guard selectedHandle != nil else { return }
        copy(sender)
        deleteSelected(actionName: "Cut")
    }

    func deleteSelected(actionName: String? = nil) {
        guard let handle = selectedHandle else { return }
        switch handle {
        case .row(let r): deleteRow(r, actionName: actionName ?? "Delete Row")
        case .column(let c): deleteColumn(c, actionName: actionName ?? "Delete Column")
        }
    }

    func deleteRow(_ row: Int, actionName: String = "Delete Row") {
        guard table.rowCount > 1 else { return deleteTable(actionName: actionName) }
        var newTable = table
        newTable.deleteRow(at: row)
        structuralCommit(newTable, actionName: actionName)
    }

    func deleteColumn(_ column: Int, actionName: String = "Delete Column") {
        guard table.columnCount > 1 else { return deleteTable(actionName: actionName) }
        var newTable = table
        newTable.deleteColumn(at: column)
        structuralCommit(newTable, actionName: actionName)
    }

    func insertRow(at index: Int) {
        var newTable = table
        newTable.insertRow(at: index)
        structuralCommit(newTable, actionName: "Insert Row")
    }

    func insertColumn(at index: Int) {
        var newTable = table
        newTable.insertColumn(at: index)
        structuralCommit(newTable, actionName: "Insert Column")
    }

    func setAlignment(_ alignment: MarkdownTable.Alignment, column: Int) {
        var newTable = table
        newTable.setAlignment(alignment, column: column)
        structuralCommit(newTable, actionName: "Align Column")
    }

    /// Moves a row or column to the drop gap (the gap above row `gap`, or left of column `gap`).
    func move(_ handle: TableHandle, toGap gap: Int) {
        var newTable = table
        let destination: Int
        switch handle {
        case .row(let r):
            destination = gap > r ? gap - 1 : gap
            guard r > 0, destination != r else { return }
            newTable.moveRow(from: r, to: destination)
        case .column(let c):
            destination = gap > c ? gap - 1 : gap
            guard destination != c else { return }
            newTable.moveColumn(from: c, to: destination)
        }
        // A finished move leaves nothing selected.
        structuralCommit(newTable, actionName: handle.isRow ? "Move Row" : "Move Column")
        selectedHandle = nil
    }

    /// One undo step; the caret stays where it was.
    private func structuralCommit(_ newTable: MarkdownTable, actionName: String) {
        host?.coalescingTableEdit = nil
        let focus = focusedCell
        commit(newTable, actionName: actionName, beforeFocus: focus, afterFocus: focus)
        needsDisplay = true
    }

    /// Removes the whole table, with the line break after it, as one undo step.
    func deleteTable(actionName: String) {
        guard let host, let range = host.tableRange(ordinal: ordinal) else { return }
        let text = host.string as NSString
        var removed = range
        if NSMaxRange(range) < text.length, text.character(at: NSMaxRange(range)) == 0x0A { removed.length += 1 }
        let edit = TableEdit(ordinal: ordinal, location: removed.location, before: text.substring(with: removed), after: "",
                             beforeFocus: nil, afterFocus: nil, actionName: actionName)
        host.coalescingTableEdit = nil
        host.window?.makeFirstResponder(host)
        host.replaceTableText(removed, with: "")
        host.registerTableEdit(edit)
        host.setSelectedRange(NSRange(location: min(removed.location, (host.string as NSString).length), length: 0))
    }
}

private extension TableHandle {
    var isRow: Bool { if case .row = self { true } else { false } }
}
#endif
