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
    static let boxPattern = #"\[[ xX/\-<>?!*"lbiSIpcfkwud]\]"#

    static func isMarker(_ c: unichar) -> Bool { utf16Set.contains(c) }
}
