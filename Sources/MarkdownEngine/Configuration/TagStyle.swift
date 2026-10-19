//
//  TagStyle.swift
//  MarkdownEngine
//
//  Fork: `#tags` as bubbles in one tint, with the `#` fainter. On the
//  caret's line a tag is plain source. A click on a bubble goes to the text
//  view's `onTagClick`.
//

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

public struct TagStyle: Sendable, Equatable {
    /// The bubble; its `text` colours the tag.
    public var bubble: InlineBubble
    /// The `#`'s opacity against the tag's colour.
    public var hashAlpha: CGFloat

    public init(bubble: InlineBubble, hashAlpha: CGFloat = 0.65) {
        var bubble = bubble
        bubble.padsOutsideText = true
        self.bubble = bubble
        self.hashAlpha = hashAlpha
    }
}

extension NSAttributedString.Key {
    /// Fork: the tag a drawn `#tag` names, without its `#`, as written.
    static let markdownTag = NSAttributedString.Key("MarkdownTag")
}
