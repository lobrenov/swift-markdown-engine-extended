//
//  MarkdownStyler+Tables.swift
//  MarkdownEngine
//
//  GFM tables. The block is rendered to a single PlatformImage and emitted via
//  the same collapsedSource path block-LaTeX uses, so the source stays
//  in sync with the document but the user only sees the rendered grid
//  when the caret is outside the table.
//

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import Foundation
import MarkdownEngineSyntax

extension MarkdownStyler {

    /// Rendered-table image cache. A table's pixels depend only on its source,
    /// font, colors, and appearance — so identical keys can reuse the PlatformImage
    /// instead of re-rendering every inactive table on every keystroke.
    private static let tableImageCache: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        // Must exceed a document's unique-table count or a full restyle (load /
        // theme / font change) re-renders every table (same thrash class as the
        // metadata cap). NSCache still auto-evicts under memory pressure.
        cache.countLimit = 2048
        return cache
    }()

    /// Pixel-level fingerprint of a theme color: its sRGB components resolved
    /// under `appearance`. PlatformColor descriptions are not sound identities —
    /// named dynamic colors describe by name only (two providers collide),
    /// unnamed ones by per-instance UUID (never hit) — so key on what actually
    /// reaches the bitmap.
    private static func colorKey(_ color: PlatformColor, under appearance: PlatformAppearance) -> String {
        var rgba: (CGFloat, CGFloat, CGFloat, CGFloat)?
        appearance.performAsCurrentDrawingAppearance {
            rgba = color.rgbaComponents
        }
        guard let c = rgba else { return "\(color)" }
        return String(format: "%.4f,%.4f,%.4f,%.4f", c.0, c.1, c.2, c.3)
    }

    /// Resolving six colors per table per keystroke is measurable (10 tables ×
    /// 6 appearance-scoped resolutions). The resolved prefix depends only on
    /// the color INSTANCES + appearance + font, so memoize it by identity —
    /// theme copies keep the same PlatformColor references across keystrokes.
    private static let themeKeyLock = NSLock()
    private static var themeKeyCache: [String: String] = [:]

    private static func themeKeyPrefix(ctx: StylingContext, appearance: PlatformAppearance) -> String {
        let theme = ctx.configuration.theme
        let identity = "\(ctx.baseFont.fontName)|\(ctx.baseFont.pointSize)|\(appearance.cacheKey)|"
            + "\(ObjectIdentifier(theme.bodyText))|\(ObjectIdentifier(theme.mutedText))|"
            + "\(ObjectIdentifier(theme.highlightColor))|\(ObjectIdentifier(ctx.codeBackgroundColor))|"
            + "\(ObjectIdentifier(theme.latexLightModeText))|\(ObjectIdentifier(theme.latexDarkModeText))|"
            + "\(ObjectIdentifier(type(of: ctx.services.latex)))"

        themeKeyLock.lock()
        if let cached = themeKeyCache[identity] {
            themeKeyLock.unlock()
            return cached
        }
        themeKeyLock.unlock()

        // Every input renderTable reads must be in the key: fonts, all theme
        // colors it draws with, and the latex renderer (by type — a NoOp and a
        // real renderer must not share entries).
        let prefix = [
            ctx.baseFont.fontName,
            "\(ctx.baseFont.pointSize)",
            appearance.cacheKey,
            colorKey(theme.bodyText, under: appearance),
            colorKey(theme.mutedText, under: appearance),
            colorKey(theme.highlightColor, under: appearance),
            colorKey(ctx.codeBackgroundColor, under: appearance),
            colorKey(theme.latexLightModeText, under: appearance),
            colorKey(theme.latexDarkModeText, under: appearance),
            "\(ObjectIdentifier(type(of: ctx.services.latex)))",
        ].joined(separator: "|")

        themeKeyLock.lock()
        if themeKeyCache.count > 32 { themeKeyCache.removeAll() }
        themeKeyCache[identity] = prefix
        themeKeyLock.unlock()
        return prefix
    }

    /// Parse + content-hash for a table source, memoized: both are pure in
    /// the source text but were recomputed for every table on every keystroke
    /// (the non-render share of styleTables). FIFO-capped like the block token
    /// memo — the cap MUST exceed a document's table count, else cyclic access
    /// over the full table set is Bélády-pessimal under FIFO (~100% miss) and
    /// every table re-parses+re-hashes every keystroke.
    private static let tableMetaCap = 8192
    private static let tableMetaLock = NSLock()
    private static var tableMetaCache: [String: (parsed: MarkdownTable?, hash: Int)] = [:]
    private static var tableMetaOrder: [String] = []

    static func tableMeta(for source: String) -> (parsed: MarkdownTable?, hash: Int) {
        tableMetaLock.lock()
        if let cached = tableMetaCache[source] {
            tableMetaLock.unlock()
            return cached
        }
        tableMetaLock.unlock()

        let computed = (parseTableSource(source), stableTableContentHash(for: source))

        tableMetaLock.lock()
        if tableMetaCache[source] == nil {
            tableMetaCache[source] = computed
            tableMetaOrder.append(source)
            if tableMetaOrder.count > tableMetaCap {
                tableMetaCache[tableMetaOrder.removeFirst()] = nil
            }
        }
        tableMetaLock.unlock()
        return computed
    }

    /// Returns the rendered image for `source`, from cache when possible.
    /// `rendered` is true only when a fresh render actually happened.
    /// `availableWidth` caps the table's width (cells wrap onto extra lines);
    /// it is part of the cache key because the layout depends on it.
    static func tableImage(
        for source: String,
        parsed: MarkdownTable,
        ctx: StylingContext,
        appearance: PlatformAppearance,
        availableWidth: CGFloat
    ) -> (image: PlatformImage, rendered: Bool) {
        // Rendering consumes the exact point width. Key it losslessly as well:
        // fractional SwiftUI/split-view widths can differ by more than 0.5 pt
        // while rounding to the same integer, which would otherwise reuse a
        // stale image with the wrong wrapping, height, or right inset.
        let widthKey = Double(availableWidth).bitPattern
        // The extension registry is part of the key: `==x==` in a cell renders
        // highlighted under one config and literal under another — those must
        // never share a cached image.
        let extensionKey = ctx.configuration.extensionRegistry.fingerprint
        let key = (themeKeyPrefix(ctx: ctx, appearance: appearance) + "|x\(extensionKey)|w\(widthKey)|" + source) as NSString
        if let cached = tableImageCache.object(forKey: key) {
            return (cached, false)
        }
        let image = renderTable(
            parsed,
            baseFont: ctx.baseFont,
            theme: ctx.configuration.theme,
            codeBackgroundColor: ctx.codeBackgroundColor,
            latex: ctx.services.latex,
            appearance: appearance,
            availableWidth: availableWidth,
            extensions: ctx.configuration.extensions
        )
        tableImageCache.setObject(image, forKey: key)
        return (image, true)
    }

    static func styleTables(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        // Per-content occurrence counter so identical tables get distinct sourceIDs.
        var occurrenceByContentHash: [Int: Int] = [:]
        var tableCount = 0
        var renderedCount = 0
        let tablesT0 = DispatchTime.now().uptimeNanoseconds
        // Iterate the pre-classified table array (not all document tokens).
        // The occurrence counter exists for stable duplicate-table sourceIDs,
        // and a sourceID is only CONSUMED by a table that renders this pass
        // (inactive + in scope). Equal content implies equal source length,
        // so only tables sharing a length with a rendering table can affect
        // its occurrence index — every other inactive table skips the
        // substring + parse/hash AND the .spellingState write (applied
        // UNCLIPPED, it used to touch every table in the document on every
        // keystroke). Typing prose renders no table → all tables skip.
        let tableIndexed = ctx.tableIndexed
        var neededLengths: Set<Int> = []
        for (idx, token) in tableIndexed
        where !ctx.activeTokenIndices.contains(idx) && !ctx.outsideScope(token.range) {
            neededLengths.insert(token.range.length)
        }
        var skippedCount = 0
        var metaNanos: UInt64 = 0
        for (ordinal, (idx, token)) in tableIndexed.enumerated() {
            tableCount += 1
            #if os(macOS)
            // Fork: the live grid draws the table over its hidden source; the caret never reveals it.
            if ctx.configuration.liveTables {
                if ctx.outsideScope(token.range) { continue }
                attrs.append((token.range, [.spellingState: 0]))
                appendTableGrid(ordinal: ordinal, token: token, ctx: ctx, attrs: &attrs)
                continue
            }
            #endif
            if !ctx.activeTokenIndices.contains(idx),
               !neededLengths.contains(token.range.length) {
                skippedCount += 1
                continue
            }
            // Tokenizer already drops tables overlapping fenced code, so no re-check here.
            attrs.append((token.range, [.spellingState: 0]))

            let metaT0 = DispatchTime.now().uptimeNanoseconds
            let source = ctx.nsText.substring(with: token.range)
            let meta = tableMeta(for: source)
            metaNanos &+= DispatchTime.now().uptimeNanoseconds - metaT0
            guard let parsed = meta.parsed else { continue }

            // Advance occurrence index even for active/out-of-scope tables so
            // inactive duplicates keep stable sourceIDs.
            let occurrenceIndex = occurrenceByContentHash[meta.hash, default: 0]
            occurrenceByContentHash[meta.hash] = occurrenceIndex + 1

            let isActive = ctx.activeTokenIndices.contains(idx)
            if isActive {
                // Caret inside the table — show editable source, pipes muted like other syntax.
                let muted = ctx.configuration.theme.mutedText
                let body = ctx.configuration.theme.bodyText
                attrs.append((token.range, [.foregroundColor: body, .font: ctx.baseFont]))
                // Mute each `|` so the structure stays legible while editing.
                let end = NSMaxRange(token.range)
                var i = token.range.location
                while i < end {
                    if ctx.nsText.character(at: i) == 0x7C {   // '|'
                        attrs.append((NSRange(location: i, length: 1), [.foregroundColor: muted]))
                    }
                    i += 1
                }
                continue
            }

            // Outside the restyle scope the anchor attrs would be clipped away
            // at application time — skip the render lookup and anchor build
            // (occurrence bookkeeping above already ran, keeping IDs stable).
            if ctx.outsideScope(token.range) { continue }

            // See renderTable: resolve table colors under the text view's real appearance.
            let renderAppearance = currentAppearance(of: ctx.layoutBridge?.firstTextContainer?.textView)
            // Cells wrap to the container width (Obsidian-style); the render
            // only exceeds it when the per-column floors genuinely don't fit,
            // in which case the scrollable overlay below takes over.
            let containerWidth = effectiveContainerWidth(for: ctx)
            let (image, rendered) = tableImage(
                for: source,
                parsed: parsed,
                ctx: ctx,
                appearance: renderAppearance,
                availableWidth: containerWidth
            )
            if rendered { renderedCount += 1 }
            let imageBounds = CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
            // Wide tables → scrollable mode (NSScrollView overlay); narrow → collapsed.
            // Geometry is fractional in split-view and SwiftUI layouts. Use
            // only a floating-point noise allowance here; a real sub-point
            // overflow still needs horizontal scrolling.
            let widthEpsilon = max(
                image.size.width.ulp,
                containerWidth.ulp
            ) * 8
            let isWide = image.size.width - containerWidth > widthEpsilon
            let computedSourceID = stableTableSourceID(
                for: source,
                occurrenceIndex: occurrenceIndex
            )
            let mode: RenderedStandaloneBlockMode = isWide
                ? .collapsedSourceScrollable(
                    markerTexts: [],
                    displayWidth: containerWidth,
                    sourceID: computedSourceID
                )
                : .collapsedSource(markerTexts: [])
            _ = appendRenderedStandaloneBlock(
                for: token,
                rawContent: source,
                image: image,
                imageBounds: imageBounds,
                paragraphSpacingBefore: ctx.baseDefaultLineHeight * 0.5,
                paragraphSpacing: ctx.baseDefaultLineHeight * 0.5,
                alignment: .left,
                mode: mode,
                restyleOnWidthChange: true,
                ctx: ctx,
                attrs: &attrs
            )
        }
        if tableCount > 0 {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - tablesT0) / 1_000_000
            let metaMs = Double(metaNanos) / 1_000_000
            PerfTrace.note { "styleTables scanned=\(tableCount) tables (skipped=\(skippedCount)), re-rendered=\(renderedCount) PlatformImage in \(String(format: "%.2f", ms))ms (substring+meta=\(String(format: "%.2f", metaMs))ms)" }
        }
        return attrs
    }

    #if os(macOS)
    /// Fork: reserves the live grid's space on the table's first line, which the grid sits over. The height is the
    /// grid's last measured one for this table (`NativeTextView.tableGridHeights`), else the layout's estimate.
    private static func appendTableGrid(
        ordinal: Int, token: MarkdownToken, ctx: StylingContext, attrs: inout [StyledRange]
    ) {
        let source = ctx.nsText.substring(with: token.range)
        guard let parsed = tableMeta(for: source).parsed else { return }
        let containerWidth = effectiveContainerWidth(for: ctx)
        let layout = tableLayout(
            parsed, baseFont: ctx.baseFont, theme: ctx.configuration.theme,
            codeBackgroundColor: ctx.codeBackgroundColor, latex: ctx.services.latex,
            availableWidth: containerWidth, extensions: ctx.configuration.extensions
        ).layout
        let host = ctx.layoutBridge?.firstTextContainer?.textView as? NativeTextView
        // A measured height is the whole reservation, scroller strip included.
        let measured = host?.tableGridHeights[ordinal]
        let height = measured ?? layout.size.height
        let isWide = measured == nil && layout.size.width - containerWidth > max(layout.size.width.ulp, containerWidth.ulp) * 8
        let bounds = CGRect(x: 0, y: 0, width: layout.size.width, height: height)
        _ = appendRenderedStandaloneBlock(
            for: token,
            rawContent: source,
            image: NSImage(size: bounds.size),
            imageBounds: bounds,
            paragraphSpacingBefore: ctx.baseDefaultLineHeight * 0.5,
            paragraphSpacing: ctx.baseDefaultLineHeight * 0.5,
            alignment: .left,
            mode: .collapsedSourceScrollable(
                markerTexts: [], displayWidth: containerWidth, sourceID: ordinal,
                scrollerStrip: isWide ? MarkdownTextLayoutFragment.scrollableBlockScrollerStrip : 0
            ),
            restyleOnWidthChange: true,
            ctx: ctx,
            attrs: &attrs
        )
    }
    #endif

    // MARK: - Parsing

    /// Fork: parsing lives in `MarkdownTable`.
    static func parseTableSource(_ source: String) -> MarkdownTable? {
        MarkdownTable.parse(source)
    }

    // MARK: - Inline-formatted cell strings

    /// `<br>` → a real newline. A GFM row IS one source line, so `<br>` is the
    /// only in-cell line break the format has; without this it drew literally.
    static func expandCellLineBreaks(_ raw: String) -> String {
        raw.replacingOccurrences(
            of: #"<br\s*/?>"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    /// Raw cell → `NSAttributedString`: inline markdown applied, markers stripped, LaTeX as attachments.
    static func formattedCellString(
        _ raw: String,
        baseFont: PlatformFont,
        header: Bool,
        theme: MarkdownEditorTheme,
        codeBackgroundColor: PlatformColor,
        latex: any LatexRenderer,
        extensions: [any MarkdownExtension] = []
    ) -> NSAttributedString {
        let descriptor = baseFont.fontDescriptor
        let pointSize = baseFont.pointSize
        let codeFont = PlatformFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        let startFont = header
            ? (PlatformFont(descriptor: descriptor.withSymbolicTraits(.bold), size: pointSize) ?? baseFont)
            : baseFont
        let out = NSMutableAttributedString()
        var extensionsByID: [String: any MarkdownExtension] = [:]
        for ext in extensions { extensionsByID[ext.id] = ext }
        // Substituted BEFORE inline parsing so the AST offsets index the same
        // string that gets drawn.
        let raw = expandCellLineBreaks(raw)
        appendInlineCell(
            InlineParser.parse(raw, registry: ExtensionRegistry(extensions: extensions)),
            in: raw as NSString, into: out,
            font: startFont, baseDescriptor: descriptor, pointSize: pointSize,
            codeFont: codeFont, theme: theme, codeBackgroundColor: codeBackgroundColor, latex: latex,
            extensionsByID: extensionsByID
        )
        return out
    }

    /// Compose `current`'s bold/italic traits with `kind` so nested emphasis stacks (italic+bold).
    private static func composeEmphasis(
        _ current: PlatformFont, _ kind: EmphasisKind,
        baseDescriptor: PlatformFontDescriptor, pointSize: CGFloat
    ) -> PlatformFont {
        var traits = current.fontDescriptor.symbolicTraits.intersection([.bold, .italic])
        switch kind {
        case .bold: traits.insert(.bold)
        case .italic: traits.insert(.italic)
        case .boldItalic: traits.formUnion([.bold, .italic])
        }
        return PlatformFont(descriptor: baseDescriptor.withSymbolicTraits(traits), size: pointSize) ?? current
    }

    /// Walk the inline AST into marker-stripped runs; LaTeX as attachments, links/embeds emitted raw.
    private static func appendInlineCell(
        _ nodes: [InlineNode],
        in ns: NSString,
        into out: NSMutableAttributedString,
        font: PlatformFont,
        baseDescriptor: PlatformFontDescriptor,
        pointSize: CGFloat,
        codeFont: PlatformFont,
        theme: MarkdownEditorTheme,
        codeBackgroundColor: PlatformColor,
        latex: any LatexRenderer,
        extensionsByID: [String: any MarkdownExtension] = [:]
    ) {
        func recurse(_ children: [InlineNode], _ f: PlatformFont) {
            appendInlineCell(children, in: ns, into: out, font: f, baseDescriptor: baseDescriptor,
                             pointSize: pointSize, codeFont: codeFont, theme: theme,
                             codeBackgroundColor: codeBackgroundColor, latex: latex,
                             extensionsByID: extensionsByID)
        }
        func appendPlain(_ range: NSRange, _ f: PlatformFont) {
            out.append(NSAttributedString(string: ns.substring(with: range),
                                          attributes: [.font: f, .foregroundColor: theme.bodyText]))
        }
        for node in nodes {
            switch node {
            case .text(let r):
                appendPlain(r, font)
            case .escape(_, let character, _):
                appendPlain(character, font)
            case .tag(let r, _):
                appendPlain(r, font)
            case .emphasis(let kind, _, _, let children):
                recurse(children, composeEmphasis(font, kind, baseDescriptor: baseDescriptor, pointSize: pointSize))
            case .ext(let extNode):
                let start = out.length
                if extNode.children.isEmpty {
                    appendPlain(extNode.contentRange, font)
                } else {
                    recurse(extNode.children, font)
                }
                if out.length > start, let ext = extensionsByID[extNode.extensionID] {
                    let span = NSRange(location: start, length: out.length - start)
                    var attributes = ext.contentAttributes(theme: theme)
                    // A cell rasterizes through NSAttributedString drawing, which
                    // knows nothing of the line-box fill the layout fragment paints
                    // — fall back to the glyph-box background so a highlight inside
                    // a table still has one.
                    if let fill = attributes.removeValue(forKey: .markdownBlockBackground) {
                        attributes[.backgroundColor] = fill
                    }
                    out.addAttributes(attributes, range: span)
                }
            case .code(_, let content):
                out.append(NSAttributedString(string: ns.substring(with: content), attributes: [
                    .font: codeFont, .backgroundColor: codeBackgroundColor, .foregroundColor: theme.bodyText
                ]))
            case .inlineLatex(let range, let content, _):
                if let entry = latex.render(
                    latex: ns.substring(with: content),
                    mode: .inline,
                    fontSize: pointSize,
                    theme: theme
                ) {
                    let attachment = NSTextAttachment()
                    attachment.image = entry.image
                    attachment.bounds = CGRect(x: 0, y: entry.baselineOffset,
                                               width: entry.size.width, height: entry.size.height)
                    out.append(NSAttributedString(attachment: attachment))
                } else {
                    appendPlain(range, font)   // renderer unavailable → keep raw `$…$`
                }
            case .link(let range, _, _, _, _),
                 .image(let range, _, _, _),
                 .wikiLink(let range, _, _, _),
                 .imageEmbed(let range, _, _):
                appendPlain(range, font)
            }
        }
    }

    // MARK: - Rendering

    /// Fork: a table's geometry, shared by the rendered image and the live grid.
    struct TableLayout {
        static let cellHPadding: CGFloat = 12
        static let cellVPadding: CGFloat = 6
        static let borderWidth: CGFloat = 1

        let columnWidths: [CGFloat]
        let rowContentHeights: [CGFloat]
        let columnLeft: [CGFloat]
        let rowTop: [CGFloat]
        let size: CGSize

        init(columnWidths: [CGFloat], rowContentHeights: [CGFloat]) {
            let (hPad, vPad, border) = (Self.cellHPadding, Self.cellVPadding, Self.borderWidth)
            let columnCount = columnWidths.count
            let rowCount = rowContentHeights.count
            self.columnWidths = columnWidths
            self.rowContentHeights = rowContentHeights
            size = CGSize(
                width: columnWidths.reduce(0, +) + CGFloat(columnCount) * 2 * hPad + CGFloat(columnCount + 1) * border,
                height: rowContentHeights.reduce(0) { $0 + $1 + 2 * vPad } + CGFloat(rowCount + 1) * border
            )
            // Top-down coordinates; drawing runs flipped.
            var columnLeft = [CGFloat](repeating: 0, count: columnCount + 1)
            columnLeft[0] = border
            for i in 0..<columnCount {
                columnLeft[i + 1] = columnLeft[i] + columnWidths[i] + 2 * hPad + border
            }
            var rowTop = [CGFloat](repeating: 0, count: rowCount + 1)
            rowTop[0] = border
            for i in 0..<rowCount {
                rowTop[i + 1] = rowTop[i] + rowContentHeights[i] + 2 * vPad + border
            }
            self.columnLeft = columnLeft
            self.rowTop = rowTop
        }
    }

    /// Fork: a live grid's own measures of its cells, which replace the inline estimates: a cell's width on one
    /// line (list indents, boxes and bubbles included) and its content height at a width, by row (the header is 0).
    struct LiveCellMetrics {
        var natural: (_ row: Int, _ column: Int) -> CGFloat
        var height: (_ row: Int, _ column: Int, _ width: CGFloat) -> CGFloat
    }

    /// The layout of `table` within `availableWidth`, and its formatted cells (header first, then the body rows).
    static func tableLayout(
        _ table: MarkdownTable,
        baseFont: PlatformFont,
        theme: MarkdownEditorTheme,
        codeBackgroundColor: PlatformColor,
        latex: any LatexRenderer,
        availableWidth: CGFloat,
        extensions: [any MarkdownExtension] = [],
        live: LiveCellMetrics? = nil
    ) -> (layout: TableLayout, header: [NSAttributedString], body: [[NSAttributedString]]) {
        let columnCount = table.alignments.count
        let cellHPadding = TableLayout.cellHPadding
        let borderWidth = TableLayout.borderWidth
        let baseLineHeight: CGFloat = ceil(baseFont.ascender - baseFont.descender + baseFont.leading)
        let minColumnContentWidth: CGFloat = 16

        // Pre-format every cell so width measurement and drawing share one NSAttributedString.
        let headerCells = table.header.map {
            formattedCellString(
                $0, baseFont: baseFont, header: true, theme: theme,
                codeBackgroundColor: codeBackgroundColor, latex: latex,
                extensions: extensions
            )
        }
        let bodyCells = table.rows.map { row in
            row.map {
                formattedCellString(
                    $0, baseFont: baseFont, header: false, theme: theme,
                    codeBackgroundColor: codeBackgroundColor, latex: latex,
                    extensions: extensions
                )
            }
        }

        // CSS automatic table layout (W3C 17.5.2.2), which is what browser-based
        // editors like Obsidian get for free: each column has a MAXIMUM width
        // (content on one line) and a MINIMUM width (MCW — content may wrap but
        // must not overflow, i.e. the widest unbreakable whitespace-separated
        // segment). Measured segment-by-segment: a too-narrow boundingRect
        // would emergency-break INSIDE words and understate the minimum.
        func widestUnbreakableSegment(_ cell: NSAttributedString) -> CGFloat {
            let str = cell.string as NSString
            let whitespace = CharacterSet.whitespacesAndNewlines
            var widest: CGFloat = 0
            var segStart = -1
            for i in 0...str.length {
                let isBreak = i == str.length || {
                    guard let scalar = Unicode.Scalar(str.character(at: i)) else { return false }
                    return whitespace.contains(scalar)
                }()
                if isBreak {
                    if segStart >= 0 {
                        let segment = cell.attributedSubstring(from: NSRange(location: segStart, length: i - segStart))
                        widest = max(widest, ceil(segment.size().width))
                        segStart = -1
                    }
                } else if segStart < 0 {
                    segStart = i
                }
            }
            return widest
        }
        var maxWidths = [CGFloat](repeating: minColumnContentWidth, count: columnCount)
        var minWidths = [CGFloat](repeating: minColumnContentWidth, count: columnCount)
        // `size()` lays a cell out as ONE line, so a cell broken by `<br>`
        // would report the sum of its lines as its natural width.
        func naturalWidth(_ cell: NSAttributedString) -> CGFloat {
            guard cell.string.contains("\n") else { return ceil(cell.size().width) }
            return ceil(cell.boundingRect(
                with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin],
                context: nil
            ).width)
        }
        func considerCell(_ cell: NSAttributedString, row: Int, col: Int) {
            let inline = naturalWidth(cell)
            guard let live else {
                maxWidths[col] = max(maxWidths[col], inline)
                minWidths[col] = max(minWidths[col], widestUnbreakableSegment(cell))
                return
            }
            // The cell's real width on one line; what it adds to the inline text (a list's indent) is in its minimum too.
            let real = live.natural(row, col)
            maxWidths[col] = max(maxWidths[col], real)
            minWidths[col] = max(minWidths[col], min(real, widestUnbreakableSegment(cell) + max(0, real - inline)))
        }
        for (i, cell) in headerCells.enumerated() where i < columnCount {
            considerCell(cell, row: 0, col: i)
        }
        for (r, row) in bodyCells.enumerated() {
            for (i, cell) in row.enumerated() where i < columnCount {
                considerCell(cell, row: r + 1, col: i)
            }
        }

        // Distribute the available width:
        // - everything fits on one line → natural (maximum) widths;
        // - too wide → shrink to the available width, but never below a
        //   column's longest unbreakable word; the slack above the minimums is
        //   distributed proportionally to each column's (max − min) stretch;
        // - even the minimums don't fit (many-column tables) → columns stay at
        //   their minimums, the table renders wider than the container, and
        //   the horizontal-scroll overlay takes over as before.
        let chrome = CGFloat(columnCount) * 2 * cellHPadding
            + CGFloat(columnCount + 1) * borderWidth
        let contentAvailable = availableWidth - chrome
        let sumMax = maxWidths.reduce(0, +)
        let sumMin = minWidths.reduce(0, +)
        var columnWidths = maxWidths
        if contentAvailable > 0, sumMax > contentAvailable {
            if sumMin >= contentAvailable {
                columnWidths = minWidths
            } else if live != nil {
                // Columns share the width in proportion to their natural widths, none below its minimum.
                var fixed = Set<Int>()
                var shared = maxWidths
                while true {
                    let free = (0..<columnCount).filter { !fixed.contains($0) }
                    let remaining = contentAvailable - fixed.reduce(0) { $0 + minWidths[$1] }
                    let scale = remaining / free.reduce(0) { $0 + maxWidths[$1] }
                    let tooSmall = free.filter { maxWidths[$0] * scale < minWidths[$0] }
                    if tooSmall.isEmpty {
                        for i in free { shared[i] = maxWidths[i] * scale }
                        break
                    }
                    tooSmall.forEach { fixed.insert($0); shared[$0] = minWidths[$0] }
                }
                columnWidths = shared
            } else {
                let extra = contentAvailable - sumMin
                let totalStretch = sumMax - sumMin
                columnWidths = zip(minWidths, maxWidths).map { mn, mx in
                    mn + (mx - mn) / totalStretch * extra
                }
            }
        }

        // Per-row heights: each row is as tall as its tallest (wrapped) cell.
        func cellHeight(_ cell: NSAttributedString, row: Int, col: Int) -> CGFloat {
            if let live { return live.height(row, col, columnWidths[col]) }
            let bounds = cell.boundingRect(
                with: CGSize(width: columnWidths[col], height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin],
                context: nil
            )
            return ceil(bounds.height)
        }
        let rowCount = 1 + table.rows.count // header + body rows
        var rowContentHeights = [CGFloat](repeating: baseLineHeight, count: rowCount)
        for (i, cell) in headerCells.enumerated() where i < columnCount {
            rowContentHeights[0] = max(rowContentHeights[0], cellHeight(cell, row: 0, col: i))
        }
        for (rowIdx, row) in bodyCells.enumerated() {
            for (i, cell) in row.enumerated() where i < columnCount {
                rowContentHeights[rowIdx + 1] = max(rowContentHeights[rowIdx + 1], cellHeight(cell, row: rowIdx + 1, col: i))
            }
        }

        return (TableLayout(columnWidths: columnWidths, rowContentHeights: rowContentHeights), headerCells, bodyCells)
    }

    private static func renderTable(
        _ table: MarkdownTable,
        baseFont: PlatformFont,
        theme: MarkdownEditorTheme,
        codeBackgroundColor: PlatformColor,
        latex: any LatexRenderer,
        appearance: PlatformAppearance,
        availableWidth: CGFloat,
        extensions: [any MarkdownExtension] = []
    ) -> PlatformImage {
        let columnCount = table.alignments.count
        let cellHPadding = TableLayout.cellHPadding
        let cellVPadding = TableLayout.cellVPadding
        let borderWidth = TableLayout.borderWidth
        // Resolve under the real appearance: `.withAlphaComponent()` freezes a dynamic color otherwise.
        func mutedColor(alpha: CGFloat) -> PlatformColor {
            theme.mutedText.resolved(under: appearance).withAlphaComponent(alpha)
        }
        let borderColor = mutedColor(alpha: 0.5)
        let (layout, headerCells, bodyCells) = tableLayout(
            table, baseFont: baseFont, theme: theme, codeBackgroundColor: codeBackgroundColor,
            latex: latex, availableWidth: availableWidth, extensions: extensions
        )
        let (size, columnLeft, rowTop, rowContentHeights) = (layout.size, layout.columnLeft, layout.rowTop, layout.rowContentHeights)
        let rowCount = layout.rowContentHeights.count

        let alignments = table.alignments
        let headerFill = mutedColor(alpha: 0.08)

        // Flipped image so AppKit handles the y-flip; a manual transform mirror would flip glyphs too.
        return drawnImage(size: size) {
            // Header row fill
            headerFill.setFill()
            PlatformBezierPath(rect: CGRect(
                x: borderWidth,
                y: borderWidth,
                width: size.width - 2 * borderWidth,
                height: rowContentHeights[0] + 2 * cellVPadding
            )).fill()

            // Outer border
            borderColor.setStroke()
            let outer = PlatformBezierPath(rect: CGRect(
                x: borderWidth / 2,
                y: borderWidth / 2,
                width: size.width - borderWidth,
                height: size.height - borderWidth
            ))
            outer.lineWidth = borderWidth
            outer.stroke()

            // Internal separators
            let separators = PlatformBezierPath()
            separators.lineWidth = borderWidth
            for i in 1..<columnCount {
                let x = columnLeft[i] - borderWidth / 2
                separators.move(to: CGPoint(x: x, y: 0))
                separators.line(to: CGPoint(x: x, y: size.height))
            }
            for i in 1..<rowCount {
                let y = rowTop[i] - borderWidth / 2
                separators.move(to: CGPoint(x: 0, y: y))
                separators.line(to: CGPoint(x: size.width, y: y))
            }
            separators.stroke()

            func drawCell(_ s: NSAttributedString, col: Int, row: Int) {
                guard col < columnCount else { return }
                let cellLeft = columnLeft[col] + cellHPadding
                let cellRight = columnLeft[col + 1] - borderWidth - cellHPadding
                let cellContentWidth = cellRight - cellLeft
                // Align via NSParagraphStyle; word-wrap fills the row height
                // measured above (long words fall back to character breaks).
                let paragraph = NSMutableParagraphStyle()
                switch alignments[col] {
                case .left, .none: paragraph.alignment = .left
                case .center: paragraph.alignment = .center
                case .right:  paragraph.alignment = .right
                }
                paragraph.lineBreakMode = .byWordWrapping
                let aligned = NSMutableAttributedString(attributedString: s)
                aligned.addAttribute(
                    .paragraphStyle,
                    value: paragraph,
                    range: NSRange(location: 0, length: aligned.length)
                )
                let drawRect = CGRect(
                    x: cellLeft,
                    y: rowTop[row] + cellVPadding,
                    width: cellContentWidth,
                    height: rowContentHeights[row]
                )
                aligned.draw(with: drawRect, options: [.usesLineFragmentOrigin], context: nil)
            }

            for (col, cell) in headerCells.enumerated() {
                drawCell(cell, col: col, row: 0)
            }
            for (rowIdx, row) in bodyCells.enumerated() {
                for (col, cell) in row.enumerated() {
                    drawCell(cell, col: col, row: rowIdx + 1)
                }
            }
        }
    }

    // MARK: - Scrollable table helpers

    /// Container width with fallback chain for "styler runs before layout" case.
    static func effectiveContainerWidth(for ctx: StylingContext) -> CGFloat {
        if let container = ctx.layoutBridge?.firstTextContainer {
            // During SwiftUI-hosted window resizing, PlatformTextView bounds can be
            // updated before a width-tracking NSTextContainer publishes its
            // derived size. The view is the width owner in this mode, so use
            // its live geometry instead of rerasterizing tables at a stale
            // container width. Fixed reading columns do not track the view and
            // continue to use their explicit container width below.
            if container.widthTracksTextView, let textView = container.textView {
                let inset = textView.textContainerInset
                let usable = textView.bounds.width - inset.width * 2
                if usable.isFinite, usable > 0 { return usable }
            }
            let raw = container.size.width
            if raw.isFinite, raw > 0, raw < 100_000 { return raw }
            if let textView = container.textView {
                let inset = textView.textContainerInset
                let usable = textView.bounds.width - inset.width * 2
                if usable.isFinite, usable > 0 { return usable }
                let frameUsable = textView.frame.width - inset.width * 2
                if frameUsable.isFinite, frameUsable > 0 { return frameUsable }
            }
        }
        return 500
    }

    /// Content-only hash; intentionally collides for identical tables — disambiguated by occurrence index.
    static func stableTableContentHash(for source: String) -> Int {
        var hasher = Hasher()
        hasher.combine("table-overlay-v1")
        hasher.combine(source)
        return hasher.finalize()
    }

    /// Per-instance ID = (content, nth-occurrence); stable across re-styles so scroll offsets persist.
    static func stableTableSourceID(for source: String, occurrenceIndex: Int) -> Int {
        var hasher = Hasher()
        hasher.combine("table-overlay-v2")
        hasher.combine(source)
        hasher.combine(occurrenceIndex)
        return hasher.finalize()
    }
}
