//
//  TextMark.swift
//  MarkdownEngine
//
//  Fork: an opt-in hook that marks spans of plain text, as attributes only, and reports a click on one. The text
//  is never changed. See `MarkdownEditorConfiguration.textMarks`.
//

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Fork: a span of text the embedder marks (see `MarkdownEditorConfiguration.textMarks`).
public struct TextMark: Sendable {
    /// UTF-16 offsets within the text the hook was given.
    public var range: Range<Int>
    /// What `onTextMarkClick` reports for a click on the span.
    public var id: String
    /// A single underline in this colour; nil adds none.
    public var underline: PlatformColor?
    /// The text colour; nil keeps it.
    public var color: PlatformColor?
    /// The body font in bold. Headings are bold already and ignore it.
    public var bold: Bool

    public init(range: Range<Int>, id: String, underline: PlatformColor? = nil, color: PlatformColor? = nil,
                bold: Bool = false) {
        self.range = range
        self.id = id
        self.underline = underline
        self.color = color
        self.bold = bold
    }
}

extension NSAttributedString.Key {
    /// Fork: the id of the `TextMark` over a character.
    static let markdownTextMark = NSAttributedString.Key("MarkdownTextMark")
}
