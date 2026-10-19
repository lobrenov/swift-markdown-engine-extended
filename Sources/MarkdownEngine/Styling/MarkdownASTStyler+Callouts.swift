//
//  MarkdownASTStyler+Callouts.swift
//  MarkdownEngine
//
//  Fork: styles a blockquote that holds callouts (see `Callout`). Each
//  line gets a `.calloutLine` that the fragment draws its slice of every
//  panel from, plus the indents and spacing that put its text inside them.
//  A folded callout's body lines shrink to nothing, unless the caret is in
//  the body.
//

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// How a blockquote with callouts lays out on screen: which callouts are folded and which lines that hides.
struct CalloutQuoteLayout {
    let lines: [QuoteLine]
    let callouts: [Callout]
    /// Per callout: its body is hidden.
    let folded: [Bool]
    /// Per line: inside a folded callout's body.
    let hidden: [Bool]

    init?(range: NSRange, ctx: MarkdownASTStyler.Ctx) {
        guard ctx.config.callouts != nil else { return nil }
        let lines = QuoteLine.lines(in: range, of: ctx.ns)
        let callouts = Callout.find(in: lines, of: ctx.ns)
        guard !callouts.isEmpty else { return nil }
        let folded = callouts.map { callout -> Bool in
            guard callout.header.fold.length == 1, callout.hasBody else { return false }
            let key = ctx.ns.substring(with: lines[callout.first].text)
            let isFolded = ctx.config.calloutFoldOverrides[key]
                ?? (ctx.ns.character(at: callout.header.fold.location) == 0x2D /* - */)
            let body = NSRange(location: lines[callout.first + 1].line.location,
                               length: NSMaxRange(lines[callout.last].line) - lines[callout.first + 1].line.location)
            return isFolded && !ctx.isActive(body)
        }
        var hidden = Array(repeating: false, count: lines.count)
        for (callout, isFolded) in zip(callouts, folded) where isFolded {
            for i in (callout.first + 1)...callout.last { hidden[i] = true }
        }
        self.lines = lines
        self.callouts = callouts
        self.folded = folded
        self.hidden = hidden
    }

    /// The last line a callout's panel covers: its title when folded.
    func panelEnd(_ callout: Int) -> Int {
        folded[callout] ? callouts[callout].first : callouts[callout].last
    }

    /// The callouts whose panels cover line `index`, outer first.
    func visibleCallouts(holding index: Int) -> [Int] {
        callouts.indices.filter { callouts[$0].first <= index && index <= panelEnd($0) && !hidden[callouts[$0].first] }
    }

    /// The name shown for an untitled callout: `faq` shows "Faq".
    static func displayName(of type: String) -> String {
        type.prefix(1).uppercased() + type.dropFirst().lowercased()
    }

    static func titleFont(_ ctx: MarkdownASTStyler.Ctx) -> PlatformFont {
        let descriptor = ctx.baseFont.fontDescriptor.addingAttributes([
            .traits: [PlatformFontDescriptor.TraitKey.weight: PlatformFont.Weight.semibold],
        ])
        return PlatformFont(descriptor: descriptor, size: ctx.baseFont.pointSize) ?? ctx.baseFont
    }
}

extension MarkdownASTStyler {

    /// Styles a blockquote holding callouts; false when it holds none.
    static func styleCalloutQuote(range: NSRange, items: [ListItem], ctx: Ctx, into attrs: inout [StyledRange]) -> Bool {
        guard let style = ctx.config.callouts, let layout = CalloutQuoteLayout(range: range, ctx: ctx) else { return false }
        let lines = layout.lines
        let callouts = layout.callouts
        let barStep = MarkdownTextLayoutFragment.blockquoteIndentPerLevel
        let itemsByLine = Dictionary(uniqueKeysWithValues: items.map { ($0.range.location, $0) })
        let titleFont = CalloutQuoteLayout.titleFont(ctx)
        let visibleLines = lines.indices.filter { lines[$0].level > 0 && !layout.hidden[$0] }

        for (i, line) in lines.enumerated() where line.level > 0 {
            let isHidden = layout.hidden[i]
            let holding = layout.visibleCallouts(holding: i)

            // Each level is a panel (a callout) or a bar (a plain quote), left to right.
            var panels: [(callout: Int, x: CGFloat, depth: Int)] = []
            var bars: [CGFloat] = []
            var x: CGFloat = 0
            var endsWithBar = false
            for level in 1...line.level {
                if let callout = holding.first(where: { callouts[$0].level == level }) {
                    panels.append((callout, x, panels.count))
                    x += style.paddingSide
                    endsWithBar = false
                } else {
                    bars.append(x + barStep * 0.25)
                    x += barStep
                    endsWithBar = true
                }
            }
            let textIndent = x + (endsWithBar ? barStep * 0.5 : 0)
            let title = holding.last.flatMap { callouts[$0].first == i ? $0 : nil }

            // Panels ending here, inner first, each padded below the one inside it.
            var bottomPadding: [Int: CGFloat] = [:]
            var padding: CGFloat = 0
            for callout in holding.reversed() where layout.panelEnd(callout) == i && !isHidden {
                padding += layout.folded[callout] || !callouts[callout].hasBody ? style.paddingBottomFolded : style.paddingBottom
                bottomPadding[callout] = padding
            }
            // Hidden lines take no space; the visible line above them carries the spacing.
            let above = visibleLines.last { $0 < i }
            let closedAbove = above.map { line in layout.visibleCallouts(holding: line).contains { layout.panelEnd($0) == line } } ?? false
            let parentTitleAbove = holding.count > 1 && callouts[holding[holding.count - 2]].first == above
            var spacingBefore: CGFloat = 0
            if title != nil {
                spacingBefore = style.paddingTop + (above != nil && !closedAbove && !parentTitleAbove ? style.blockSpacing : 0)
            }
            var spacingAfter = padding
            if let title, callouts[title].hasBody, !layout.folded[title] { spacingAfter += style.titleSpacing }
            if isHidden {
                spacingAfter = 0
            } else if i == visibleLines.last {
                spacingAfter += ctx.baseParagraphSpacing
            } else if !bottomPadding.isEmpty {
                spacingAfter += style.blockSpacing
            }

            // On the caret's line the `>` markers show, hanging left of the text so it stays put.
            let isActive = ctx.isActive(line.text)
            let markerWidth = isActive ? HeadingHelpers.textWidth(ctx.ns.substring(with: line.markers), font: ctx.baseFont) : 0
            let para = NSMutableParagraphStyle()
            para.firstLineHeadIndent = textIndent - markerWidth
            para.headIndent = textIndent
            para.tailIndent = -CGFloat(panels.count) * style.paddingSide
            if let title, callouts[title].header.fold.length == 1 {
                para.tailIndent -= style.chevronSize + style.chevronGap
            }
            let lineHeight = isHidden ? 0.1 : ctx.baseLineHeight + ctx.config.blockquote.extraLineHeight
            para.minimumLineHeight = lineHeight
            para.maximumLineHeight = lineHeight
            para.paragraphSpacing = spacingAfter
            para.paragraphSpacingBefore = spacingBefore
            attrs.append((ctx.ns.paragraphRange(for: line.text), [.paragraphStyle: para]))

            if line.content.length > 0 {
                attrs.append((line.content, [.foregroundColor: endsWithBar ? ctx.theme.mutedText : style.bodyColor]))
            }
            attrs.append((line.markers, isActive
                ? [.foregroundColor: ctx.theme.mutedText]
                : [.foregroundColor: PlatformColor.clear, .font: ctx.inlineMarkerFont]))

            var drawnTitle: CalloutLine.Title?
            if let title {
                let header = callouts[title].header
                attrs.append((header.title, [.font: titleFont, .foregroundColor: style.titleColor]))
                let type = ctx.ns.substring(with: header.type)
                if !isActive {
                    let depth = panels.count - 1
                    drawnTitle = CalloutLine.Title(
                        type: type, tint: style.tint(type), drawIcon: style.drawIcon,
                        iconX: textIndent, iconSize: style.iconSize,
                        name: header.title.length == 0 ? CalloutQuoteLayout.displayName(of: type) : nil,
                        nameX: textIndent + style.iconSize + style.iconGap, font: titleFont, color: style.titleColor,
                        folded: header.fold.length == 1 ? layout.folded[title] : nil,
                        chevronRightInset: CGFloat(depth + 1) * style.paddingSide, chevronSize: style.chevronSize,
                        chevronColor: style.foldColor)
                }
            }
            let calloutPanels = panels.map { panel -> CalloutLine.Panel in
                let callout = callouts[panel.callout]
                let tint = style.tint(ctx.ns.substring(with: callout.header.type))
                return CalloutLine.Panel(
                    x: panel.x, rightInset: CGFloat(panel.depth) * style.paddingSide,
                    opens: callout.first == i, topPadding: style.paddingTop, bottomPadding: bottomPadding[panel.callout],
                    fill: tint.withAlphaComponent(tint.alphaComponent * style.fillOpacity),
                    ring: tint.withAlphaComponent(tint.alphaComponent * style.ringOpacity),
                    targetRing: style.targetColor, cornerRadius: style.cornerRadius,
                    titleLocation: lines[callout.first].line.location)
            }
            attrs.append((line.text, [.calloutLine: CalloutLine(
                panels: calloutPanels, bars: isHidden ? [] : bars, title: drawnTitle,
                isTitle: title != nil, isFolded: title.map { layout.folded[$0] } ?? false)]))

            if !isHidden, let item = itemsByLine[line.line.location] {
                styleListItem(item, displayNumber: nil,
                              quote: QuoteLayout(indent: textIndent, spacing: spacingAfter,
                                                 spacingBefore: spacingBefore, tailIndent: para.tailIndent,
                                                 markerWidth: markerWidth),
                              ctx: ctx, into: &attrs)
            }
        }
        return true
    }

    /// Runs after every other pass, so it wins: hides each title's `[!type]` behind its icon (or mutes it on the
    /// caret's line) and hides folded bodies.
    static func finishCallouts(in blocks: [BlockNode], ctx: Ctx, into attrs: inout [StyledRange]) {
        guard let style = ctx.config.callouts else { return }
        for block in blocks where ctx.inScope(block.range) {
            guard case .blockquote(let range, _, _) = block, let layout = CalloutQuoteLayout(range: range, ctx: ctx) else { continue }
            for callout in layout.callouts where !layout.hidden[callout.first] {
                let header = callout.header
                guard header.syntax.length > 0 else { continue }
                if ctx.isActive(layout.lines[callout.first].text) {
                    attrs.append((header.syntax, [.foregroundColor: ctx.theme.mutedText]))
                    continue
                }
                var slot = style.iconSize + style.iconGap
                if header.title.length == 0 {
                    let name = CalloutQuoteLayout.displayName(of: ctx.ns.substring(with: header.type))
                    slot += HeadingHelpers.textWidth(name, font: CalloutQuoteLayout.titleFont(ctx))
                }
                attrs.append((header.syntax, [.font: ctx.inlineMarkerFont, .foregroundColor: PlatformColor.clear, .kern: -ctx.inlineMarkerFont.pointSize]))
                attrs.append((NSRange(location: NSMaxRange(header.syntax) - 1, length: 1), [.kern: slot]))
            }
            for (line, isHidden) in zip(layout.lines, layout.hidden) where isHidden {
                attrs.append((line.line, [
                    .font: ctx.inlineMarkerFont, .foregroundColor: PlatformColor.clear, .kern: -ctx.inlineMarkerFont.pointSize,
                    .backgroundColor: PlatformColor.clear, .markdownInlineBubble: NSNull(),
                    .underlineStyle: 0, .strikethroughStyle: 0,
                ]))
            }
        }
    }
}
