//
//  CalloutStyle.swift
//  MarkdownEngine
//
//  Fork: how Obsidian callouts draw. A quote whose first line is
//  `> [!type]` (optionally `+` or `-`, then a title) becomes a tinted panel
//  with an icon and the title; its other `>` lines are the body. The embedder
//  maps each type, as written, to a tint and an icon.
//

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

public struct CalloutStyle: Sendable {
    /// The type's colour, given the type as written (`faq`, `Warning`, `recipe`).
    public var tint: @Sendable (_ type: String) -> PlatformColor
    /// Draws the type's icon into the current (flipped) graphics context.
    public var drawIcon: @Sendable (_ type: String, _ rect: CGRect, _ tint: PlatformColor) -> Void
    public var titleColor: PlatformColor
    public var bodyColor: PlatformColor
    /// The fold chevron.
    public var foldColor: PlatformColor
    /// The ring of a callout whose menu is open.
    public var targetColor: PlatformColor
    /// The panel's fill and ring, as fractions of the tint's opacity.
    public var fillOpacity: CGFloat
    public var ringOpacity: CGFloat

    public var cornerRadius: CGFloat = 10
    public var paddingTop: CGFloat = 9
    public var paddingSide: CGFloat = 14
    public var paddingBottom: CGFloat = 11
    /// The bottom padding of a callout showing its title only.
    public var paddingBottomFolded: CGFloat = 9
    /// Between the title and the body.
    public var titleSpacing: CGFloat = 3
    /// Between a nested callout and the body text around it.
    public var blockSpacing: CGFloat = 8
    public var iconSize: CGFloat = 16
    public var iconGap: CGFloat = 8
    public var chevronSize: CGFloat = 14
    public var chevronGap: CGFloat = 8

    public init(tint: @escaping @Sendable (String) -> PlatformColor,
                drawIcon: @escaping @Sendable (String, CGRect, PlatformColor) -> Void,
                titleColor: PlatformColor, bodyColor: PlatformColor, foldColor: PlatformColor, targetColor: PlatformColor,
                fillOpacity: CGFloat, ringOpacity: CGFloat) {
        self.tint = tint
        self.drawIcon = drawIcon
        self.titleColor = titleColor
        self.bodyColor = bodyColor
        self.foldColor = foldColor
        self.targetColor = targetColor
        self.fillOpacity = fillOpacity
        self.ringOpacity = ringOpacity
    }
}
