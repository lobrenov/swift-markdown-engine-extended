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
}
