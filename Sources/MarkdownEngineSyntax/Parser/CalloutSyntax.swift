//
//  CalloutSyntax.swift
//  MarkdownEngineSyntax
//
//  Fork: Obsidian's callout types and their aliases (`spec/data/callout-types.json`). The parser reads any
//  type; this is the table a consumer names them by.
//

import Foundation

public enum CalloutSyntax {
    /// A callout type.
    public struct Kind: Hashable, Sendable {
        /// As written between `[!` and `]`, lowercased.
        public let id: String
        /// Other names that take its look.
        public let aliases: [String]
    }

    /// Every type, in menu order.
    public static let types: [Kind] = [
        ("note", []), ("abstract", ["summary", "tldr"]), ("info", []), ("todo", []), ("tip", ["hint", "important"]),
        ("success", ["check", "done"]), ("question", ["help", "faq"]), ("warning", ["caution", "attention"]),
        ("failure", ["fail", "missing"]), ("danger", ["error"]), ("bug", []), ("example", []), ("quote", ["cite"]),
    ].map { Kind(id: $0.0, aliases: $0.1) }

    /// The type an unknown name reads as.
    public static let unknownType = "note"

    /// The id `name` (as written between `[!` and `]`) names, ignoring case; nil for an unknown type.
    public static func type(named name: String) -> String? {
        let name = name.lowercased()
        return types.first { $0.id == name || $0.aliases.contains(name) }?.id
    }
}
