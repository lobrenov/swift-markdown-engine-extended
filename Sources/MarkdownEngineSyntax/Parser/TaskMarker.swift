//
//  TaskMarker.swift
//  MarkdownEngine
//
//  Fork: the characters accepted between a task item's brackets.
//  GFM's `[ ]` / `[x]` / `[X]` plus the Alternative Checkboxes Reference Set
//  (https://github.com/damiankorcz/Alternative-Checkboxes-Reference-Set).
//

import Foundation

public enum TaskMarker {
    /// Every marker character the engine renders as a checkbox.
    public static let all: [Character] = [
        " ", "x", "X",
        "/", "-", ">", "<", "?", "!", "*", "\"", "l", "b", "i", "S", "I", "p", "c", "f", "k", "w", "u", "d",
    ]

    static let utf16Set: Set<unichar> = Set(all.map { $0.utf16.first! })

    /// Regex fragment matching one box, e.g. `[ ]`, `[x]` or `[/]`.
    package static let boxPattern = #"\[[ xX/\-<>?!*"lbiSIpcfkwud]\]"#

    static func isMarker(_ c: unichar) -> Bool { utf16Set.contains(c) }

    /// Fork: the recommended reading of a marker (`spec/data/task-markers.json`).
    public enum State: Sendable {
        case open, done, cancelled
        /// Drawn as a box, not a task.
        case icon
    }

    /// Fork: the recommended state of `marker`; nil for a character that isn't a marker.
    public static func state(of marker: Character) -> State? {
        switch marker {
        case " ", "/", ">", "<": .open
        case "x", "X": .done
        case "-": .cancelled
        default: all.contains(marker) ? .icon : nil
        }
    }

    /// Fork: what a toggle sets: `x` for an open marker, a space for a done or cancelled one, nothing for an icon.
    public static func toggled(_ marker: Character) -> Character? {
        switch state(of: marker) {
        case .open: "x"
        case .done, .cancelled: " "
        case .icon, nil: nil
        }
    }

    /// Fork: where a list item's box starts after its marker, which ends at `markerEnd` (GFM: one to four spaces
    /// or tabs, `[c]` with a marker `c`, then a space or tab). The `[`'s offset; nil without a box.
    package static func boxStart(in chars: (Int) -> unichar, markerEnd: Int, end: Int) -> Int? {
        func isSpace(_ at: Int) -> Bool { at < end && (chars(at) == 0x20 || chars(at) == 0x09) }
        var box = markerEnd
        while box - markerEnd < 4, isSpace(box) { box += 1 }
        guard box > markerEnd, box + 3 < end, chars(box) == 0x5B, chars(box + 2) == 0x5D, isSpace(box + 3),
              isMarker(chars(box + 1)) else { return nil }
        return box
    }

    /// Fork: the box at the start of `text`, the rest of a list item's line after its marker (after `-`, `*`,
    /// `+`, `1.` or `1)`), by the list-item parser's rule: its marker and the marker's UTF-16 offset in `text`.
    public static func box(inTextAfterListMarker text: some StringProtocol) -> (marker: Character, offset: Int)? {
        let ns = String(text) as NSString
        guard let box = boxStart(in: { ns.character(at: $0) }, markerEnd: 0, end: ns.length) else { return nil }
        return (Character(UnicodeScalar(ns.character(at: box + 1))!), box + 1)
    }
}
