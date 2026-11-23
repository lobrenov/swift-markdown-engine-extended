//
//  MarkdownTextLayoutFragment+TaskAttributes.swift
//  MarkdownEngine
//
//  Fork: draws each `.markdownTaskAttribute` span as a pill (icon, label) in the room its hidden source reserves.
//

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

extension MarkdownTextLayoutFragment {

    /// The pill of a span whose first character starts at `x`, with its text's baseline at `baselineY`.
    static func taskAttributePill(of span: TaskAttributeSpan, x: CGFloat, baselineY: CGFloat) -> CGRect {
        let labelFont = TaskAttributeSpan.labelFont(span.font, span.style)
        let top = baselineY - labelFont.ascender - span.style.verticalPadding
        let bottom = baselineY - labelFont.descender + span.style.verticalPadding
        return CGRect(x: x + span.style.margin, y: top, width: span.width, height: bottom - top)
    }

    func drawTaskAttributes(at point: CGPoint, in context: CGContext) {
        guard let storage = textStorage, let range = fragmentNSRange, range.length > 0 else { return }
        pushGraphicsContext(context)
        defer { popGraphicsContext() }
        storage.enumerateAttribute(.markdownTaskAttribute, in: range, options: []) { [weak self] value, attrRange, _ in
            guard let self, let span = value as? TaskAttributeSpan,
                  let start = drawPosition(forDocumentCharAt: attrRange.location, point: point) else { return }
            let rect = Self.taskAttributePill(of: span, x: start.x, baselineY: start.baselineY)
            let style = span.style
            let chip = span.chip
            let radius = min(style.cornerRadius, rect.height / 2)
            let fill = chip.fill ?? chip.tint.withAlphaComponent(style.fillOpacity)
            context.setFillColor(fill.cgColor)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()

            let labelFont = TaskAttributeSpan.labelFont(span.font, style)
            var x = rect.minX + style.horizontalPadding
            if let drawIcon = chip.drawIcon {
                let size = TaskAttributeSpan.iconSize(labelFont)
                drawIcon(CGRect(x: x, y: rect.midY - size / 2, width: size, height: size), chip.tint)
                x += size + style.iconGap
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: chip.tint]
            if chip.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            (chip.label as NSString).draw(at: CGPoint(x: x, y: start.baselineY - labelFont.ascender), withAttributes: attributes)
        }
    }
}
