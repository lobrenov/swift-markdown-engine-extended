//
//  MarkdownTokenAttributes.swift
//  MarkdownEngine
//
//  Fork: text attributes the styler sets for wiki-links and task boxes (from `MarkdownToken.swift`, so the parser
//  imports Foundation only).
//

import Foundation

extension NSAttributedString.Key {
    public static let wikiLinkID = NSAttributedString.Key("NodeLinkID")
    public static let taskCheckbox = NSAttributedString.Key("TaskCheckbox")
    /// Fork: the task marker (a `String`) whose box draws before a wiki-link's text, on its opening `[[`.
    static let markdownWikiLinkBox = NSAttributedString.Key("MarkdownWikiLinkBox")
}
