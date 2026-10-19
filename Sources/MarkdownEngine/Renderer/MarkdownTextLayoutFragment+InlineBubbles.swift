//
//  MarkdownTextLayoutFragment+InlineBubbles.swift
//  MarkdownEngine
//
//  Fork: draws each `.markdownInlineBubble` span as a rounded fill, once
//  per line it wraps onto. The span's hidden markers are kerned to the
//  bubble's padding, so the bubble's ends sit in that space; where the span
//  wraps, the end reaches past the text by the padding instead.
//

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

extension MarkdownTextLayoutFragment {

    /// One rect per line each bubble touches, relative to `point`.
    func inlineBubbleShapes(at point: CGPoint) -> [(rect: CGRect, bubble: InlineBubble)] {
        guard let storage = textStorage, let range = fragmentNSRange, range.length > 0 else { return [] }
        var shapes: [(rect: CGRect, bubble: InlineBubble)] = []
        storage.enumerateAttribute(.markdownInlineBubble, in: range, options: []) { value, spanRange, _ in
            guard let bubble = (value as? InlineBubbleSpan)?.bubble else { return }
            let local = NSRange(location: spanRange.location - range.location, length: spanRange.length)
            for lineFragment in textLineFragments {
                let lineRange = lineFragment.characterRange
                let hit = NSIntersectionRange(lineRange, local)
                guard hit.length > 0 else { continue }
                let bounds = lineFragment.typographicBounds
                let glyphs = glyphEdges(of: lineFragment)
                let startX = glyphs.start[hit.location - lineRange.location]
                    ?? lineFragment.locationForCharacter(at: hit.location).x
                let endX = glyphs.end[NSMaxRange(hit) - 1 - lineRange.location]
                    ?? (NSMaxRange(hit) >= NSMaxRange(lineRange)
                        ? bounds.width
                        : lineFragment.locationForCharacter(at: NSMaxRange(hit)).x)
                let left = hit.location == local.location && !bubble.padsOutsideText
                    ? startX + bubble.margin : startX - bubble.horizontalPadding
                let right = NSMaxRange(hit) == NSMaxRange(local) ? endX - bubble.margin : endX + bubble.horizontalPadding
                guard right > left else { continue }

                // The tallest font in the segment: the content's, not a hidden marker's.
                var font: PlatformFont?
                storage.enumerateAttribute(.font, in: NSRange(location: range.location + hit.location, length: hit.length),
                                           options: []) { value, _, _ in
                    if let candidate = value as? PlatformFont, candidate.pointSize > (font?.pointSize ?? 0) { font = candidate }
                }
                guard let font else { continue }
                let baseline = point.y + bounds.origin.y + lineFragment.locationForCharacter(at: hit.location).y
                let top = baseline - font.ascender - bubble.verticalPadding
                let bottom = baseline - font.descender + bubble.verticalPadding
                shapes.append((CGRect(x: point.x + bounds.origin.x + left, y: top, width: right - left, height: bottom - top),
                               bubble))
            }
        }
        return shapes
    }

    /// Where each character's glyph starts and ends, by index in the line. Caret offsets put half a kern before the
    /// next character; the glyph runs put all of it after the kerned glyph, as it draws.
    private func glyphEdges(of line: NSTextLineFragment) -> (start: [Int: CGFloat], end: [Int: CGFloat]) {
        let text = line.attributedString.attributedSubstring(from: line.characterRange)
        var start: [Int: CGFloat] = [:]
        var end: [Int: CGFloat] = [:]
        for run in CTLineGetGlyphRuns(CTLineCreateWithAttributedString(text as CFAttributedString)) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetPositions(run, CFRange(), &positions)
            CTRunGetAdvances(run, CFRange(), &advances)
            CTRunGetStringIndices(run, CFRange(), &indices)
            for k in 0..<count {
                start[indices[k]] = min(start[indices[k]] ?? .infinity, positions[k].x)
                end[indices[k]] = max(end[indices[k]] ?? -.infinity, positions[k].x + advances[k].width)
            }
        }
        return (start, end)
    }

    func drawInlineBubbles(at point: CGPoint, in context: CGContext) {
        let shapes = inlineBubbleShapes(at: point)
        guard !shapes.isEmpty else { return }
        for (rect, bubble) in shapes {
            let radius = min(bubble.cornerRadius, rect.height / 2, rect.width / 2)
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.saveGState()
            // The selection shows through, as it does through code blocks.
            context.addPath(path)
            context.clip()
            context.addRect(rect)
            for selection in selectionRectsInDrawCoordinates(drawPoint: point, snappedY: rect.minY, snappedMaxY: rect.maxY) {
                context.addRect(selection.intersection(rect))
            }
            context.setFillColor(bubble.fill.cgColor)
            context.fillPath(using: .evenOdd)
            context.restoreGState()
            if let ring = bubble.ring {
                let inset = rect.insetBy(dx: 0.5, dy: 0.5)
                let ringRadius = max(0, radius - 0.5)
                context.addPath(CGPath(roundedRect: inset, cornerWidth: ringRadius, cornerHeight: ringRadius, transform: nil))
                context.setStrokeColor(ring.cgColor)
                context.setLineWidth(1)
                context.strokePath()
            }
        }
    }
}
