//
//  InlineBubble.swift
//  MarkdownEngine
//
//  Fork: a rounded fill behind an inline span (inline code, a
//  highlight), drawn again on each line the span wraps onto. Set it on
//  `InlineCodeStyle.bubble`, or return it from `MarkdownExtension.bubble(theme:)`.
//

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

public struct InlineBubble: Sendable, Equatable {
    public var fill: PlatformColor
    /// A 1pt ring inside the bubble's edge; none when nil.
    public var ring: PlatformColor?
    /// The span's text colour; nil keeps the surrounding colour.
    public var text: PlatformColor?
    /// Space between the text and the bubble's left and right edges.
    public var horizontalPadding: CGFloat
    /// Space between the bubble and the text beside it; negative overlaps it.
    public var margin: CGFloat
    /// How far the bubble reaches above the ascender and below the descender.
    public var verticalPadding: CGFloat
    public var cornerRadius: CGFloat
    /// Whether the bubble reaches past the span's first and last glyphs by the padding, for a span with no hidden
    /// markers to sit in it. The styler kerns the characters around the span to make room.
    var padsOutsideText = false

    public init(fill: PlatformColor, ring: PlatformColor? = nil, text: PlatformColor? = nil, horizontalPadding: CGFloat,
                margin: CGFloat = 0, verticalPadding: CGFloat = 2, cornerRadius: CGFloat = 6) {
        self.fill = fill
        self.ring = ring
        self.text = text
        self.horizontalPadding = horizontalPadding
        self.margin = margin
        self.verticalPadding = verticalPadding
        self.cornerRadius = cornerRadius
    }

    /// The advance a hidden marker takes on each side, so the text clears the bubble's padding.
    var markerAdvance: CGFloat { horizontalPadding + margin }
}

/// The `.markdownInlineBubble` value: one object per span, so its runs join up when fonts split them.
final class InlineBubbleSpan: NSObject {
    let bubble: InlineBubble

    init(_ bubble: InlineBubble) {
        self.bubble = bubble
    }
}

extension NSAttributedString.Key {
    /// Fork: an `InlineBubbleSpan` over a whole span, its markers included.
    static let markdownInlineBubble = NSAttributedString.Key("MarkdownInlineBubble")
}
