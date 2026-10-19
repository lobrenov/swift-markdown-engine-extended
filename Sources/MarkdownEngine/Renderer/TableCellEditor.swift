//
//  TableCellEditor.swift
//  MarkdownEngine
//
//  Fork: one cell of a live table grid. It is the editor itself (a `NativeTextView` with its own coordinator)
//  running the host's configuration minus tables and embeds, so a cell shows and does what the document does: syntax
//  hides until the cell has the keyboard. The grid writes each change through `MarkdownTable`.
//

#if os(macOS)
import AppKit
import SwiftUI
import MarkdownEngineSyntax

final class TableCellEditor {
    let textView: NativeTextView
    let coordinator: NativeTextViewCoordinator
    var row: Int
    var column: Int
    weak var grid: TableGridView?
    private let layoutDelegate = MarkdownLayoutManagerDelegate()
    private var appliedTheme: MarkdownEditorTheme?
    private var appliedWikiFingerprint: AnyHashable?
    private var appliedFont: String?
    private(set) var appliedHeader: Bool?
    private var measured: (text: String, width: CGFloat, height: CGFloat)?
    private var measuredNatural: (text: String, width: CGFloat)?

    init(host: NativeTextView, row: Int, column: Int) {
        self.row = row
        self.column = column
        textView = NativeTextView(frame: .zero)
        coordinator = NativeTextViewCoordinator(
            text: Binding(get: { "" }, set: { _ in }), fontName: host.baseFont.fontName, fontSize: host.baseFont.pointSize,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        guard let container = textView.textContainer, let tlm = textView.textLayoutManager else {
            fatalError("NSTextView did not create a TextKit 2 stack on this OS version")
        }
        let (hPad, vPad) = (MarkdownStyler.TableLayout.cellHPadding, MarkdownStyler.TableLayout.cellVPadding)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.size = NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: hPad, height: vPad)
        tlm.delegate = layoutDelegate
        coordinator.layoutDelegate = layoutDelegate
        let bridge = LayoutBridge(tlm)
        coordinator.layoutBridge = bridge
        textView.layoutBridge = bridge
        coordinator.textView = textView
        coordinator.documentId = "table-cell"
        textView.delegate = coordinator
        textView.hidesSyntaxUnlessFocused = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.allowsUndo = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = []
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.tableCell = self
        syncConfiguration(from: host)
    }

    /// The host's configuration for a cell: no tables, no embeds, no scrolling or reading column.
    func syncConfiguration(from host: NativeTextView) {
        var config = host.configuration
        let theme = config.theme
        let wiki = config.services.wikiLinks.fingerprint()
        config.liveTables = false
        config.heightBehavior = .fitsContent
        config.readingWidth = nil
        config.services.images = NoOpEmbeddedImageProvider()
        config.textInsets = TextInsets(horizontal: MarkdownStyler.TableLayout.cellHPadding,
                                       vertical: MarkdownStyler.TableLayout.cellVPadding)
        let font = cellFont(host.baseFont)
        let fontKey = "\(font.fontName)|\(font.pointSize)"
        let changed = appliedTheme != theme || appliedWikiFingerprint != wiki || appliedFont != fontKey
            || appliedHeader != (row == 0)
        coordinator.configuration = config
        textView.configuration = config
        coordinator.fontName = font.fontName
        coordinator.fontSize = font.pointSize
        textView.font = font
        textView.baseFont = font
        if changed {
            appliedTheme = theme
            appliedWikiFingerprint = wiki
            appliedFont = fontKey
            appliedHeader = row == 0
            measured = nil
            measuredNatural = nil
            config.theme.apply(to: textView)
            textView.insertionPointColor = theme.bodyText
            coordinator.cachedParsedDocument = nil
            if textView.string.isEmpty == false { restyleAll() }
        }
        syncCallbacks(from: host)
    }

    /// The embedder's closures, which it replaces on every update.
    func syncCallbacks(from host: NativeTextView) {
        textView.onTaskMarkerMenu = host.onTaskMarkerMenu
        textView.onCalloutMenu = host.onCalloutMenu
        textView.onTagClick = host.onTagClick
        if let hostCoordinator = host.delegate as? NativeTextViewCoordinator {
            coordinator.onLinkClick = hostCoordinator.onLinkClick
            coordinator.onSlashCommandChange = hostCoordinator.onSlashCommandChange
            coordinator.onInlinePreviewKey = hostCoordinator.onInlinePreviewKey
            coordinator.slashTriggers = hostCoordinator.slashTriggers.subtracting([.embed])
            coordinator.undoManagerOverride = { [weak host] in
                guard let host, let hostCoordinator = host.delegate as? NativeTextViewCoordinator else { return nil }
                return hostCoordinator.undoManager(forDocument: hostCoordinator.documentId)
            }
        }
    }

    /// The column's alignment (`.none` reads as left) on the cell's paragraphs, now and after every styling.
    func setAlignment(_ alignment: MarkdownTable.Alignment) {
        let wanted: NSTextAlignment = alignment == .center ? .center : alignment == .right ? .right : .left
        guard coordinator.paragraphAlignment != wanted else { return }
        coordinator.paragraphAlignment = wanted
        coordinator.applyParagraphAlignment(to: textView)
        if var typing = textView.typingAttributes as [NSAttributedString.Key: Any]?,
           let style = (typing[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
            style.alignment = wanted
            typing[.paragraphStyle] = style
            textView.typingAttributes = typing
        }
    }

    /// The header row's text is bold.
    private func cellFont(_ base: NSFont) -> NSFont {
        row == 0 ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
    }

    var text: String { textView.string }

    /// Replaces the cell's text and restyles it.
    func setText(_ text: String) {
        coordinator.rebuildTextStorageAndStyle(textView, from: text, invalidateLayout: true)
    }

    private func restyleAll() {
        let length = (textView.string as NSString).length
        guard length > 0 else { return }
        coordinator.restyleParagraphs([NSRange(location: 0, length: length)], in: textView)
    }

    /// The text's width laid out on one line, lines broken only by the text's own line breaks, without the cell's
    /// insets: list indents, boxes and bubbles count.
    func naturalWidth() -> CGFloat {
        if !textView.hasEditingFocus, let measuredNatural, measuredNatural.text == textView.string { return measuredNatural.width }
        guard let container = textView.textContainer, let tlm = textView.textLayoutManager else { return 0 }
        // An empty cell has no width, and no line's width depends on where its alignment would put it: measure left-aligned.
        guard !textView.string.isEmpty else {
            measuredNatural = (textView.string, 0)
            return 0
        }
        let alignment = coordinator.paragraphAlignment
        if alignment != nil, alignment != .left {
            coordinator.paragraphAlignment = .left
            coordinator.applyParagraphAlignment(to: textView)
        }
        defer {
            if alignment != nil, alignment != .left {
                coordinator.paragraphAlignment = alignment
                coordinator.applyParagraphAlignment(to: textView)
            }
        }
        container.size = NSSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude)
        tlm.invalidateLayout(for: tlm.documentRange)
        var right: CGFloat = 0
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { fragment in
            for line in fragment.textLineFragments {
                // The line's width and its indent, not where it sits: a centred or right-aligned line is placed in the
                // very wide container.
                let start = (tlm.textContentManager as? NSTextContentStorage).map {
                    $0.offset(from: $0.documentRange.location, to: fragment.rangeInElement.location)
                } ?? 0
                let style = textView.textStorage.flatMap { start >= 0 && start < $0.length
                    ? $0.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle : nil }
                right = max(right, fragment.layoutFragmentFrame.minX + (style?.firstLineHeadIndent ?? 0) + line.typographicBounds.width)
            }
            return true
        }
        let width = ceil(right)
        measuredNatural = (textView.string, width)
        return width
    }

    /// Wraps the text at `width`, the cell's content width.
    func setContentWidth(_ width: CGFloat) {
        guard let container = textView.textContainer, let tlm = textView.textLayoutManager,
              abs(container.size.width - width) > 0.01 else { return }
        container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        tlm.invalidateLayout(for: tlm.documentRange)
    }

    /// The text's height at `width` (the cell's content width), without the cell's insets.
    func contentHeight(width: CGFloat) -> CGFloat {
        // An unchanged cell keeps its height; the cell with the keyboard is measured each time (its caret shows syntax).
        if !textView.hasEditingFocus, let measured, measured.width == width, measured.text == textView.string {
            return measured.height
        }
        let height = measureContentHeight(width: width)
        measured = (textView.string, width, height)
        return height
    }

    private func measureContentHeight(width: CGFloat) -> CGFloat {
        guard let container = textView.textContainer, let tlm = textView.textLayoutManager else { return 0 }
        if abs(container.size.width - width) > 0.01 {
            container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            tlm.invalidateLayout(for: tlm.documentRange)
        }
        textView.fitLeadingCalloutPadding()
        let lineHeight = layoutBridgeDefaultLineHeight(for: textView.baseFont, using: textView.layoutBridge)
        let total = textView.measuredBaseContentHeight(minimumHeight: lineHeight, forceFullLayout: true)
        return max(ceil(total - 2 * textView.textContainerInset.height), ceil(lineHeight))
    }
}
#endif
