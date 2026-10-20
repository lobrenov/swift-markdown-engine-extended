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

    /// Fork: the box in a list-item line (after any indent and quote `>`s): its marker and the marker's UTF-16
    /// offset in `line`. Nil when the line isn't a list item with a box.
    public static func box(inLine line: String) -> (marker: Character, offset: Int)? {
        let ns = line as NSString
        let end = ns.length
        var i = 0
        while i < end, [0x20, 0x09, 0x3E].contains(ns.character(at: i)) { i += 1 }
        let c = i < end ? ns.character(at: i) : 0
        if c == 0x2D || c == 0x2A || c == 0x2B {
            i += 1
        } else {
            let digits = i
            while i < end, i - digits < 9, ns.character(at: i) >= 0x30, ns.character(at: i) <= 0x39 { i += 1 }
            guard i > digits, i < end, ns.character(at: i) == 0x2E || ns.character(at: i) == 0x29 else { return nil }
            i += 1
        }
        guard let box = boxStart(in: { ns.character(at: $0) }, markerEnd: i, end: end) else { return nil }
        return (Character(UnicodeScalar(ns.character(at: box + 1))!), box + 1)
    }

    /// Fork: the box in `rest`, the text right after a list marker (`- `'s `-`), by the same rule: its marker
    /// and the marker's UTF-16 offset in `rest`.
    public static func box(afterListMarker rest: some StringProtocol) -> (marker: Character, offset: Int)? {
        let ns = String(rest) as NSString
        guard let box = boxStart(in: { ns.character(at: $0) }, markerEnd: 0, end: ns.length) else { return nil }
        return (Character(UnicodeScalar(ns.character(at: box + 1))!), box + 1)
    }
}
