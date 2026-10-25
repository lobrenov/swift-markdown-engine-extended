//
//  LinkPaste.swift
//  MarkdownEngine
//
//  Fork: a URL pasted over selected text makes a Markdown link.
//

import Foundation

enum LinkPaste {
    /// `[selected](url)` when `pasted` is one URL (a `://` scheme or `mailto:`, surrounding whitespace trimmed) and
    /// `selected` is text within one line; otherwise nil.
    static func link(pasting pasted: String, over selected: String) -> String? {
        let url = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty, !selected.contains(where: \.isNewline),
              !url.contains(where: \.isWhitespace),
              url.contains("://") || url.lowercased().hasPrefix("mailto:"),
              URL(string: url)?.scheme != nil else { return nil }
        return "[\(selected)](\(url))"
    }
}
