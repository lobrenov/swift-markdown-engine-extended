//
//  FileEmbedImage.swift
//  MarkdownEngine
//
//  Fork: the image a file block (an `![[ ]]` of an existing non-image file) draws as. It goes through the image
//  embed path, so selection, the source button, menus and keys act on it as on any image.
//

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import CoreGraphics

enum FileEmbedImage {
    /// The extension badge's text: the file's extension in upper case, empty when it has none.
    static func badgeText(forName name: String) -> String {
        let file = fileName(of: name)
        guard let dot = file.lastIndex(of: "."), dot != file.startIndex else { return "" }
        return String(file[file.index(after: dot)...]).uppercased()
    }

    /// The target's last path component.
    static func fileName(of target: String) -> String {
        target.split(separator: "/").last.map(String.init) ?? target
    }

    /// The badge text's size: 8pt up to 3 letters, 7.5 for 4, and longer scaled to fit `width`.
    static func badgeFontSize(forText text: String, fitting width: CGFloat, font: PlatformFont) -> CGFloat {
        if text.count <= 3 { return 8 }
        if text.count == 4 { return 7.5 }
        let measured = (text as NSString).size(withAttributes: [.font: font.withSize(7.5)]).width
        return measured > width ? 7.5 * width / measured : 7.5
    }

    static func make(
        target: String, width: CGFloat, style: ImageEmbedStyle.FileEmbedStyle, theme: MarkdownEditorTheme,
        codeBackground: PlatformColor, bodyFont: PlatformFont, codeFont: PlatformFont
    ) -> PlatformImage {
        let size = CGSize(width: width, height: style.height)
        let name = fileName(of: target)
        let badgeText = badgeText(forName: target)
        let textColor = style.text ?? theme.bodyText
        let badgeColor = style.badge ?? theme.link
        let background = style.background ?? codeBackground
        let border = style.border ?? theme.mutedText.withAlphaComponent(0.3)
        return drawnImage(size: size) {
            #if os(macOS)
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            #else
            guard let context = UIGraphicsGetCurrentContext() else { return }
            #endif
            let half = style.borderWidth / 2
            let block = CGRect(origin: .zero, size: size).insetBy(dx: half, dy: half)
            let blockPath = CGPath(roundedRect: block, cornerWidth: style.cornerRadius - half,
                                   cornerHeight: style.cornerRadius - half, transform: nil)
            context.addPath(blockPath)
            context.setFillColor(background.cgColor)
            context.fillPath()
            context.addPath(blockPath)
            context.setStrokeColor(border.cgColor)
            context.setLineWidth(style.borderWidth)
            context.strokePath()

            let badge = CGRect(x: style.leadingPadding, y: (size.height - style.badgeSize.height) / 2,
                               width: style.badgeSize.width, height: style.badgeSize.height)
            let sx = badge.width / 28, sy = badge.height / 34
            let page = CGMutablePath()
            page.move(to: CGPoint(x: 4, y: 1))
            page.addLine(to: CGPoint(x: 18, y: 1))
            page.addLine(to: CGPoint(x: 27, y: 10))
            page.addLine(to: CGPoint(x: 27, y: 30))
            page.addArc(tangent1End: CGPoint(x: 27, y: 33), tangent2End: CGPoint(x: 24, y: 33), radius: 3)
            page.addLine(to: CGPoint(x: 4, y: 33))
            page.addArc(tangent1End: CGPoint(x: 1, y: 33), tangent2End: CGPoint(x: 1, y: 30), radius: 3)
            page.addLine(to: CGPoint(x: 1, y: 4))
            page.addArc(tangent1End: CGPoint(x: 1, y: 1), tangent2End: CGPoint(x: 4, y: 1), radius: 3)
            page.closeSubpath()
            let fold = CGMutablePath()
            fold.move(to: CGPoint(x: 18, y: 1))
            fold.addLine(to: CGPoint(x: 18, y: 7))
            fold.addArc(tangent1End: CGPoint(x: 18, y: 10), tangent2End: CGPoint(x: 21, y: 10), radius: 3)
            fold.addLine(to: CGPoint(x: 27, y: 10))
            var transform = CGAffineTransform(translationX: badge.minX, y: badge.minY).scaledBy(x: sx, y: sy)
            context.saveGState()
            if let pagePath = page.copy(using: &transform), let foldPath = fold.copy(using: &transform) {
                context.addPath(pagePath)
                context.setFillColor(badgeColor.withAlphaComponent(style.badgeFillAlpha).cgColor)
                context.fillPath()
                context.setStrokeColor(badgeColor.withAlphaComponent(style.badgeOutlineAlpha).cgColor)
                context.setLineWidth(1.2)
                context.setLineJoin(.round)
                context.setLineCap(.round)
                context.addPath(pagePath)
                context.addPath(foldPath)
                context.strokePath()
            }
            context.restoreGState()

            if !badgeText.isEmpty {
                let fontSize = badgeFontSize(forText: badgeText, fitting: badge.width * 20 / 28, font: codeFont)
                let font = semibold(codeFont, size: fontSize)
                let label = NSAttributedString(string: badgeText, attributes: [.font: font, .foregroundColor: textColor])
                let labelWidth = label.size().width
                label.draw(at: CGPoint(x: badge.midX - labelWidth / 2, y: badge.minY + 26 * sy - font.ascender))
            }

            let nameX = badge.maxX + style.gap
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let label = NSAttributedString(string: name, attributes: [
                .font: bodyFont, .foregroundColor: textColor, .paragraphStyle: paragraph
            ])
            let lineHeight = ceil(bodyFont.ascender - bodyFont.descender + bodyFont.leading)
            label.draw(in: CGRect(x: nameX, y: (size.height - lineHeight) / 2,
                                  width: max(0, size.width - nameX - style.trailingPadding), height: lineHeight))
        }
    }

    private static func semibold(_ font: PlatformFont, size: CGFloat) -> PlatformFont {
        #if os(macOS)
        NSFont(descriptor: font.fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold]
        ]), size: size) ?? font.withSize(size)
        #else
        return UIFont(descriptor: font.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold]
        ]), size: size)
        #endif
    }
}
