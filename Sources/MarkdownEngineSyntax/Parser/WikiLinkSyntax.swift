//
//  WikiLinkSyntax.swift
//  MarkdownEngineSyntax
//
//  Fork: the parts of an Obsidian link, read from the text between `[[` and `]]`:
//  `target#heading|alias` or `target#^block|alias`. The `|` splits first, then the
//  first `#`; the target is trimmed of spaces and tabs.
//

import Foundation

package struct WikiLinkParts: Equatable, Sendable {
    /// The link as written before any `#` or `|`, e.g. `folder/Title`.
    package var target: String
    /// After `#`, when it doesn't start with `^`.
    package var heading: String?
    /// After `#^`.
    package var block: String?
    /// After `|`.
    package var alias: String?

    /// Nil when there's no target (`[[#heading]]`, `[[|alias]]`).
    package init?(inner: String) {
        var rest = Substring(inner)
        if let bar = rest.firstIndex(of: "|") {
            alias = String(rest[rest.index(after: bar)...])
            rest = rest[..<bar]
        }
        if let hash = rest.firstIndex(of: "#") {
            let fragment = rest[rest.index(after: hash)...]
            if fragment.first == "^" {
                block = String(fragment.dropFirst())
            } else {
                heading = String(fragment)
            }
            rest = rest[..<hash]
        }
        target = rest.trimmingCharacters(in: .whitespaces)
        if target.isEmpty { return nil }
    }
}
