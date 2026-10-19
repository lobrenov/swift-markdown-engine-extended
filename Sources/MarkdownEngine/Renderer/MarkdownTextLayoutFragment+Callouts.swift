//
//  MarkdownTextLayoutFragment+Callouts.swift
//  MarkdownEngine
//
//  Fork: each line of a callout draws its slice of every panel around
//  it (rounded at the panel's first and last lines), the bars of plain quote
//  levels, and on a title line the icon, an untitled callout's name and the
//  fold chevron. Everything comes from the line's `.calloutLine`.
//

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

extension NSAttributedString.Key {
    /// Fork: a `CalloutLine` over a line of a blockquote that holds callouts.
    static let calloutLine = NSAttributedString.Key("CalloutLine")
}

/// How one line of a blockquote with callouts draws. x positions are from the text container's left edge.
final class CalloutLine: NSObject {
    struct Panel {
        let x: CGFloat
        let rightInset: CGFloat
        /// The panel's title is on this line.
        let opens: Bool
        let topPadding: CGFloat
        /// Below this line's text, when the panel ends here.
        let bottomPadding: CGFloat?
        let fill: PlatformColor
        let ring: PlatformColor
        let targetRing: PlatformColor
        let cornerRadius: CGFloat
        /// Where the title line starts, to find the callout whose menu is open.
        let titleLocation: Int
    }

    struct Title {
        let type: String
        let tint: PlatformColor
        let drawIcon: @Sendable (String, CGRect, PlatformColor) -> Void
        let iconX: CGFloat
        let iconSize: CGFloat
        /// Drawn after the icon when the callout has no title.
        let name: String?
        let nameX: CGFloat
        let font: PlatformFont
        let color: PlatformColor
        /// nil when the callout doesn't fold.
        let folded: Bool?
        let chevronRightInset: CGFloat
        let chevronSize: CGFloat
        let chevronColor: PlatformColor
    }

    let panels: [Panel]
    let bars: [CGFloat]
    /// What to draw on a title line; nil on other lines and while the caret is on it.
    let title: Title?
    let isTitle: Bool
    /// On a title line: the body is hidden.
    let isFolded: Bool

    init(panels: [Panel], bars: [CGFloat], title: Title?, isTitle: Bool, isFolded: Bool) {
        self.panels = panels
        self.bars = bars
        self.title = title
        self.isTitle = isTitle
        self.isFolded = isFolded
    }
}

extension MarkdownTextLayoutFragment {

    var calloutLine: CalloutLine? {
        guard let storage = textStorage, let range = fragmentNSRange, range.length > 0 else { return nil }
        return storage.attribute(.calloutLine, at: range.location, effectiveRange: nil) as? CalloutLine
    }

    var hasCallout: Bool { calloutLine != nil }

    /// The fragment's height, or more where a panel ends below it: the document's last paragraph gets no spacing
    /// after it to hold the panel's bottom padding.
    var calloutSurfaceHeight: CGFloat {
        let padding = calloutLine?.panels.compactMap(\.bottomPadding).max()
        guard let padding, let last = textLines.last else { return layoutFragmentFrame.height }
        return max(layoutFragmentFrame.height, ceil(last.typographicBounds.maxY + padding + 1))
    }

    /// Above the fragment where a panel opens with no paragraph spacing to hold its top padding: the document's
    /// first paragraph.
    var calloutSurfaceTop: CGFloat {
        let padding = calloutLine?.panels.filter(\.opens).map(\.topPadding).max()
        guard let padding, let first = textLines.first else { return 0 }
        return min(0, floor(first.typographicBounds.minY - padding - 1))
    }

    private var textLines: [NSTextLineFragment] {
        textLineFragments.filter { $0.characterRange.length > 0 }
    }

    private var containerWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
    }

    func drawCalloutPanels(at point: CGPoint, in context: CGContext) {
        guard let info = calloutLine, let first = textLines.first, let last = textLines.last else { return }
        let leftEdge = point.x - layoutFragmentFrame.origin.x
        let target = (textLayoutManager?.textContainer?.textView as? NativeTextView)?.calloutMenuTarget
        for panel in info.panels {
            let left = leftEdge + panel.x
            let right = leftEdge + containerWidth - panel.rightInset
            let top = snapped(panel.opens ? point.y + first.typographicBounds.minY - panel.topPadding : point.y, point: point)
            let bottom = snapped(panel.bottomPadding.map { point.y + last.typographicBounds.maxY + $0 }
                ?? point.y + layoutFragmentFrame.height, point: point)
            guard right > left, bottom > top else { continue }
            let slice = CGRect(x: left, y: top, width: right - left, height: bottom - top)
            // The whole panel's shape, cut to this line: corners only where the panel starts and ends.
            let reach = panel.cornerRadius + 2
            var shape = slice
            if !panel.opens { shape.origin.y -= reach; shape.size.height += reach }
            if panel.bottomPadding == nil { shape.size.height += reach }
            let isTarget = target == panel.titleLocation
            let ringWidth: CGFloat = isTarget ? 2 : 1
            let ringRect = shape.insetBy(dx: ringWidth / 2, dy: ringWidth / 2)
            let ringRadius = max(0, panel.cornerRadius - ringWidth / 2)

            context.saveGState()
            context.clip(to: slice)
            context.addPath(CGPath(roundedRect: shape, cornerWidth: panel.cornerRadius, cornerHeight: panel.cornerRadius,
                                   transform: nil))
            context.setFillColor(panel.fill.cgColor)
            context.fillPath()
            context.addPath(CGPath(roundedRect: ringRect, cornerWidth: ringRadius, cornerHeight: ringRadius, transform: nil))
            context.setStrokeColor((isTarget ? panel.targetRing : panel.ring).cgColor)
            context.setLineWidth(ringWidth)
            context.strokePath()
            context.restoreGState()
        }

        guard !info.bars.isEmpty else { return }
        let theme = (textLayoutManager?.textContainer?.textView as? NativeTextView)?.configuration.theme ?? .default
        context.setFillColor(theme.mutedText.withAlphaComponent(0.5).cgColor)
        for line in textLines {
            let bounds = line.typographicBounds
            for x in info.bars {
                context.fill(CGRect(x: leftEdge + x, y: point.y + bounds.minY,
                                    width: Self.blockquoteBarWidth, height: bounds.height))
            }
        }
    }

    /// `y` on the device pixel grid of the whole document, so the slices of consecutive lines meet without a seam.
    private func snapped(_ y: CGFloat, point: CGPoint) -> CGFloat {
        let scale = displayScale(of: textLayoutManager?.textContainer?.textView)
        let documentY = layoutFragmentFrame.minY + y - point.y
        return point.y + (documentY * scale).rounded() / scale - layoutFragmentFrame.minY
    }

    func drawCalloutTitles(at point: CGPoint, in context: CGContext) {
        guard let title = calloutLine?.title, let first = textLines.first else { return }
        let leftEdge = point.x - layoutFragmentFrame.origin.x
        let bounds = first.typographicBounds
        // An untitled line holds only hidden characters, so its own baseline is theirs: centre the name instead.
        let baseline = title.name == nil
            ? point.y + bounds.minY + first.locationForCharacter(at: first.characterRange.location).y
            : point.y + bounds.midY + (title.font.ascender + title.font.descender) / 2
        let centerY = baseline - title.font.capHeight / 2

        pushGraphicsContext(context)
        defer { popGraphicsContext() }

        title.drawIcon(title.type, CGRect(x: leftEdge + title.iconX, y: centerY - title.iconSize / 2,
                                          width: title.iconSize, height: title.iconSize), title.tint)
        if let name = title.name {
            (name as NSString).draw(at: CGPoint(x: leftEdge + title.nameX, y: baseline - title.font.ascender),
                                    withAttributes: [.font: title.font, .foregroundColor: title.color])
        }
        if let folded = title.folded {
            let size = title.chevronSize
            let origin = CGPoint(x: leftEdge + containerWidth - title.chevronRightInset - size, y: centerY - size / 2)
            // The canvas's chevrons on a 16-unit grid: right when folded, down when open.
            let points: [CGPoint] = folded
                ? [CGPoint(x: 6, y: 3.5), CGPoint(x: 10.5, y: 8), CGPoint(x: 6, y: 12.5)]
                : [CGPoint(x: 3.5, y: 6), CGPoint(x: 8, y: 10.5), CGPoint(x: 12.5, y: 6)]
            let scale = size / 16
            context.addLines(between: points.map { CGPoint(x: origin.x + $0.x * scale, y: origin.y + $0.y * scale) })
            context.setStrokeColor(title.chevronColor.cgColor)
            context.setLineWidth(1.6 * scale)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        }
    }
}
