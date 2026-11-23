//
//  TaskAttributeStyle.swift
//  MarkdownEngine
//
//  Fork: a task line's attributes. `>YYYY-MM-DD` (after whitespace) is a due date and `@[[Title]]` (the `@` straight
//  before a wiki link) a parent. With `MarkdownEditorConfiguration.taskAttributes` set they are read on task lines
//  and, off the caret's line, drawn as pills in place of their source, which stays in the text: a date as the
//  embedder's short label, a parent as its icon and title. On the caret's line they are plain source. A click (a tap
//  on iOS) on one goes to the text view's `onTaskAttributeClick`.
//

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import MarkdownEngineSyntax

/// Fork: how one attribute draws, as the embedder's closures answer for it.
public struct TaskAttributeChip: Sendable {
    /// The text the pill shows.
    public var label: String
    /// The label's and the icon's colour; the fill and ring derive from it unless set.
    public var tint: PlatformColor
    /// The pill's fill; the tint at `TaskAttributeStyle.fillOpacity` when nil.
    public var fill: PlatformColor?
    /// Draws the label struck through, for a parent that doesn't resolve.
    public var strikethrough: Bool
    /// Draws an icon (in the current flipped graphics context) in the square it's given, in the tint, before the label;
    /// none when nil.
    public var drawIcon: (@Sendable (_ rect: CGRect, _ tint: PlatformColor) -> Void)?

    public init(label: String, tint: PlatformColor, fill: PlatformColor? = nil, strikethrough: Bool = false,
                drawIcon: (@Sendable (CGRect, PlatformColor) -> Void)? = nil) {
        self.label = label
        self.tint = tint
        self.fill = fill
        self.strikethrough = strikethrough
        self.drawIcon = drawIcon
    }
}

public struct TaskAttributeStyle: Sendable {
    /// The pill for a due date, given the date as written (`2026-10-02`).
    public var due: @Sendable (_ date: String) -> TaskAttributeChip
    /// The pill for a parent, given the link's bare title (no folder, `.md`, `#heading`, `^block` or `|alias`) and the
    /// wiki-link resolver's answer for the link's name (nil when it resolves to nothing).
    public var parent: @Sendable (_ title: String, _ resolution: WikiLinkResolution?) -> TaskAttributeChip
    /// Space between the pill's edge and its content.
    public var horizontalPadding: CGFloat = 6
    /// How far the pill reaches above the label's ascender and below its descender.
    public var verticalPadding: CGFloat = 1
    public var cornerRadius: CGFloat = 6
    /// The label's size against the body text's.
    public var fontScale: CGFloat = 0.92
    /// Between the icon and the label.
    public var iconGap: CGFloat = 4
    /// The fill's opacity against the tint when the chip sets none.
    public var fillOpacity: CGFloat = 0.14
    /// The space kept either side of a pill.
    public var margin: CGFloat = 2
    /// Changes whenever the closures would answer differently: a project added or renamed, a new day. The editor
    /// restyles when it changes, as it does for the wiki-link resolver's `fingerprint()`.
    public var fingerprint: @Sendable () -> AnyHashable = { 0 }

    public init(due: @escaping @Sendable (String) -> TaskAttributeChip,
                parent: @escaping @Sendable (String, WikiLinkResolution?) -> TaskAttributeChip,
                fingerprint: @escaping @Sendable () -> AnyHashable = { 0 }) {
        self.due = due
        self.parent = parent
        self.fingerprint = fingerprint
    }
}

/// Fork: a drawn attribute's `.markdownTaskAttribute` value: one object over the attribute's whole source.
final class TaskAttributeSpan: NSObject {
    let kind: TaskAttributeKind
    /// The source as written: `>2026-10-02` or `@[[Title]]`.
    let source: String
    let chip: TaskAttributeChip
    let style: TaskAttributeStyle
    let font: PlatformFont
    /// The pill's width, which the attribute's hidden source reserves.
    let width: CGFloat

    init(kind: TaskAttributeKind, source: String, chip: TaskAttributeChip, style: TaskAttributeStyle, font: PlatformFont) {
        self.kind = kind
        self.source = source
        self.chip = chip
        self.style = style
        self.font = font
        let labelFont = Self.labelFont(font, style)
        var content = (chip.label as NSString).size(withAttributes: [.font: labelFont]).width
        if chip.drawIcon != nil { content += Self.iconSize(labelFont) + style.iconGap }
        self.width = ceil(content) + 2 * style.horizontalPadding
    }

    static func labelFont(_ font: PlatformFont, _ style: TaskAttributeStyle) -> PlatformFont {
        font.withSize(font.pointSize * style.fontScale)
    }

    static func iconSize(_ labelFont: PlatformFont) -> CGFloat { ceil(labelFont.pointSize) }
}

extension MarkdownEditorConfiguration {
    /// Fork: what the wrappers compare to restyle links and pills: the wiki-link resolver's fingerprint and the task
    /// attributes' (nil when they are off).
    var linkStyleFingerprint: AnyHashable {
        AnyHashable([services.wikiLinks.fingerprint(), taskAttributes.map { $0.fingerprint() } ?? AnyHashable("off")])
    }
}

extension NSAttributedString.Key {
    /// Fork: a `TaskAttributeSpan` over a drawn attribute's source.
    static let markdownTaskAttribute = NSAttributedString.Key("MarkdownTaskAttribute")
}

/// Fork: a click on a drawn attribute, delivered to ``NativeTextViewWrapper/onTaskAttributeClick``.
public struct TaskAttributeClick {
    public let kind: TaskAttributeKind
    /// The attribute's range in the text: `>` through the date, or `@` through `]]`.
    public let range: NSRange
    /// The attribute as written: `>2026-10-02` or `@[[Title]]`.
    public let source: String
    /// The drawn pill, in screen coordinates, to anchor a menu.
    public let anchorRect: CGRect
    /// Replaces the attribute's source with `text` (`>2026-10-09`, `@[[Other]]`) as one undo step; ignored when the
    /// text there has changed since the click.
    public let replace: @MainActor (_ text: String) -> Void

    public init(kind: TaskAttributeKind, range: NSRange, source: String, anchorRect: CGRect,
                replace: @escaping @MainActor (String) -> Void) {
        self.kind = kind
        self.range = range
        self.source = source
        self.anchorRect = anchorRect
        self.replace = replace
    }
}
