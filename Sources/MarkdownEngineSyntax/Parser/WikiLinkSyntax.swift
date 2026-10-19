//
//  WikiLinkSyntax.swift
//  MarkdownEngineSyntax
//
//  Fork: the parts of an Obsidian link, read from the text between `[[` and `]]`:
//  `target#heading|alias` or `target#^block|alias`. The `|` splits first, then the
//  first `#`; the target is trimmed of spaces and tabs, and empty for the same file.
//

import Foundation

public struct WikiLinkParts: Equatable, Sendable {
    /// The link as written before any `#` or `|`, e.g. `folder/Title`.
    public var target: String
    /// After `#`, when it doesn't start with `^`.
    public var heading: String?
    /// After `#^`.
    public var block: String?
    /// After `|`.
    public var alias: String?

    /// An empty target is the same file (`[[#heading]]`, `[[#^block]]`). Nil when there's neither a target nor a
    /// heading or block (`[[|alias]]`, `[[#]]`).|alias]]`).
    public init?(inner: String) {
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
        if target.isEmpty, (heading ?? block ?? "").isEmpty { return nil }
    }
}
