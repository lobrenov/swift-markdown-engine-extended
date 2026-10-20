//
//  CalloutSyntax.swift
//  MarkdownEngineSyntax
//
//  Fork: Obsidian's callout types and their aliases (`spec/data/callout-types.json`). The parser reads any
//  type; this is the table a consumer names them by.
//

import Foundation

public enum CalloutSyntax {
    /// Each type's id and the other names that take its look, in menu order.
    public static let types: [(id: String, aliases: [String])] = [
        ("note", []), ("abstract", ["summary", "tldr"]), ("info", []), ("todo", []), ("tip", ["hint", "important"]),
        ("success", ["check", "done"]), ("question", ["help", "faq"]), ("warning", ["caution", "attention"]),
        ("failure", ["fail", "missing"]), ("danger", ["error"]), ("bug", []), ("example", []), ("quote", ["cite"]),
    ]

    /// The type an unknown name reads as.
    public static let unknownType = "note"

    /// The id `name` (as written between `[!` and `]`) names, ignoring case; nil for an unknown type.
    public static func type(named name: String) -> String? {
        let name = name.lowercased()
        return types.first { $0.id == name || $0.aliases.contains(name) }?.id
    }
}
