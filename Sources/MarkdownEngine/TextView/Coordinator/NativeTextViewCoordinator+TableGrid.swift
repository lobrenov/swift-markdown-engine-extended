//
//  NativeTextViewCoordinator+TableGrid.swift
//  MarkdownEngine
//
//  Fork: with `configuration.liveTables` the caret never rests in a table's source lines: the grid is the
//  table, so the caret steps over it as it passes (from before it to after it, and back).
//

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

extension NativeTextViewCoordinator {

    /// From every selection change: the caret steps over a table as it passes (right or left across its edge). A
    /// selection that lands in a table's lines any other way (Find, the slash menu's Table, a click that reached the
    /// text) gives the keyboard to the cell it falls in. At a document edge, stepping over adds a line to land on.
    func snapCaretOutOfTable(in textView: PlatformTextView) {
        #if os(macOS)
        let selection = textView.currentSelectedRange
        guard configuration.liveTables, let native = textView as? NativeTextView, !native.hidesSyntaxUnlessFocused,
              !native.isEditingTableText, native.focusedTableCell == nil else { return }
        let tokens = parsedDocument(for: textView.string).tableTokens
        guard let ordinal = tokens.firstIndex(where: {
            selection.location >= $0.range.location && NSMaxRange(selection) <= NSMaxRange($0.range)
        }) else { return }
        let range = tokens[ordinal].range
        if selection.length == 0 {
            let previous = previousCaretLocation
            if selection.location == range.location, previous == range.location - 1 {
                return native.leaveTable(ordinal: ordinal, above: false)
            }
            if selection.location == NSMaxRange(range), previous == NSMaxRange(range) + 1 {
                return native.leaveTable(ordinal: ordinal, above: true)
            }
        }
        // The start of the table's first line is the spot above it: typing there goes above the table.
        if selection.length == 0, selection.location == range.location || selection.location == native.tableStartLocation(range) { return }
        native.focusTableCell(ordinal: ordinal, selection: selection)
        #endif
    }
}
