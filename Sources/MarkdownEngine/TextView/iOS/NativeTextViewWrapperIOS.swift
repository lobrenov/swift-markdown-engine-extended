//
//  NativeTextViewWrapperIOS.swift
//  MarkdownEngine
//
//  The SwiftUI entry point on iOS, with the macOS wrapper's API where iOS
//  has an equivalent. The text view scrolls itself; the header scrolls with it.
//

#if os(iOS)
import SwiftUI
import UIKit

public struct NativeTextViewWrapper: UIViewRepresentable {
    public typealias Coordinator = NativeTextViewCoordinator
    public typealias UIViewType = UITextView

    @Binding public var text: String
    @Binding public var isWikiLinkActive: Bool
    public var configuration: MarkdownEditorConfiguration
    public var fontName: String
    public var fontSize: CGFloat
    public var documentId: String
    public var isEditable: Bool
    public var onLinkClick: ((String) -> Void)?
    /// A view above the text that scrolls with it (a title and properties, say).
    public var header: AnyView?
    public var onSlashCommandChange: ((SlashCommandState?) -> Void)?
    /// ↑/↓/↵/esc from a hardware keyboard while a slash, link, embed or tag query is open. Return `true` to consume
    /// the key; esc closes the query in the engine.
    public var onInlinePreviewKey: ((InlinePreviewKey) -> Bool)?
    public var slashCommandProxy: SlashCommandProxy?
    /// A press and hold on a task box: the embedder shows the marker menu.
    public var onTaskMarkerMenu: ((TaskMarkerMenuRequest) -> Void)?
    /// A press and hold on a callout's title line: the embedder shows the callout menu.
    public var onCalloutMenu: ((CalloutMenuRequest) -> Void)?
    /// A tap toggled a task box from this marker, for the embedder's haptics.
    public var onTaskCheckboxToggle: ((Character) -> Void)?
    /// A tap on a drawn `#tag` (with `configuration.tags` set), with the tag as written, without `#`.
    public var onTagClick: ((String) -> Void)?
    /// A bar above the keyboard while the editor has it (the embedder's formatting bar). It's hosted outside the
    /// SwiftUI hierarchy, so it gets no environment from here.
    public var keyboardBar: AnyView?
    /// Fork: a paste while the pasteboard has an image. Return the embed to insert on its own line (e.g.
    /// `![[Pasted image.png]]`), or nil to paste as usual.
    public var onPasteImage: ((UIPasteboard) -> String?)?
    /// Fork: a press and hold on a drawn image shows this menu there; nil shows none.
    public var imageEmbedMenu: ((ImageEmbedRequest) -> UIMenu?)?

    public init(
        text: Binding<String>,
        isWikiLinkActive: Binding<Bool> = .constant(false),
        configuration: MarkdownEditorConfiguration = .default,
        fontName: String,
        fontSize: CGFloat,
        documentId: String,
        isEditable: Bool = true,
        onLinkClick: ((String) -> Void)? = nil,
        header: AnyView? = nil,
        onSlashCommandChange: ((SlashCommandState?) -> Void)? = nil,
        onInlinePreviewKey: ((InlinePreviewKey) -> Bool)? = nil,
        slashCommandProxy: SlashCommandProxy? = nil,
        onTaskMarkerMenu: ((TaskMarkerMenuRequest) -> Void)? = nil,
        onCalloutMenu: ((CalloutMenuRequest) -> Void)? = nil,
        onTaskCheckboxToggle: ((Character) -> Void)? = nil,
        keyboardBar: AnyView? = nil,
        onPasteImage: ((UIPasteboard) -> String?)? = nil,
        imageEmbedMenu: ((ImageEmbedRequest) -> UIMenu?)? = nil,
        onTagClick: ((String) -> Void)? = nil
    ) {
        self._text = text
        self._isWikiLinkActive = isWikiLinkActive
        self.configuration = configuration
        self.fontName = fontName
        self.fontSize = fontSize
        self.documentId = documentId
        self.isEditable = isEditable
        self.onLinkClick = onLinkClick
        self.header = header
        self.onSlashCommandChange = onSlashCommandChange
        self.onInlinePreviewKey = onInlinePreviewKey
        self.slashCommandProxy = slashCommandProxy
        self.onTaskMarkerMenu = onTaskMarkerMenu
        self.onCalloutMenu = onCalloutMenu
        self.onTaskCheckboxToggle = onTaskCheckboxToggle
        self.keyboardBar = keyboardBar
        self.onPasteImage = onPasteImage
        self.imageEmbedMenu = imageEmbedMenu
        self.onTagClick = onTagClick
    }

    public func makeCoordinator() -> Coordinator {
        let coordinator = NativeTextViewCoordinator(
            text: $text,
            fontName: fontName,
            fontSize: fontSize,
            isWikiLinkActive: $isWikiLinkActive,
            onLinkClick: onLinkClick,
            onInlineSelectionChange: nil
        )
        coordinator.documentId = documentId
        coordinator.configuration = configuration
        coordinator.lastImageFingerprint = configuration.services.images.fingerprint()
        coordinator.lastWikiFingerprint = configuration.services.wikiLinks.fingerprint()
        return coordinator
    }

    public func makeUIView(context: Context) -> UITextView {
        let textView = NativeTextView()
        let coordinator = context.coordinator
        guard let textLayoutManager = textView.textLayoutManager else {
            fatalError("UITextView did not create a TextKit 2 stack")
        }
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.bodyInsets = insets
        textView.backgroundColor = .clear
        textView.isScrollEnabled = configuration.heightBehavior == .scrolls
        textView.alwaysBounceVertical = configuration.heightBehavior == .scrolls
        textView.keyboardDismissMode = .interactive
        textView.smartDashesType = .no
        textView.smartQuotesType = configuration.spellChecking.automaticQuoteSubstitution ? .yes : .no

        let layoutDelegate = MarkdownLayoutManagerDelegate()
        coordinator.layoutDelegate = layoutDelegate
        textLayoutManager.delegate = layoutDelegate
        let bridge = LayoutBridge(textLayoutManager)
        coordinator.layoutBridge = bridge
        textView.layoutBridge = bridge

        textView.configuration = configuration
        configuration.theme.apply(to: textView)
        textView.insertionPointColor = configuration.theme.bodyText
        textView.isEditable = isEditable
        let font = UIFont.named(fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
        textView.font = font
        textView.baseFont = font
        textView.baseTypingAttributes = baseTypingAttributes()

        let initialState = WikiLinkService.makeDisplayState(from: text) { configuration.services.wikiLinks.name(forID: $0) }
        textView.string = initialState.display
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.wikiLinkMetadata = initialState.metadata
        coordinator.onSlashCommandChange = onSlashCommandChange
        coordinator.onInlinePreviewKey = onInlinePreviewKey
        slashCommandProxy?.coordinator = coordinator
        textView.onTaskMarkerMenu = onTaskMarkerMenu
        textView.onCalloutMenu = onCalloutMenu
        textView.onTaskCheckboxToggle = onTaskCheckboxToggle
        textView.onTagClick = onTagClick
        textView.onPasteImage = onPasteImage
        textView.imageEmbedMenu = imageEmbedMenu
        textView.setHeader(header)
        textView.setKeyboardBar(keyboardBar)
        return textView
    }

    /// In `.fitsContent`, the height of all the text at the proposed width.
    public func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard configuration.heightBehavior == .fitsContent, let width = proposal.width, width > 0 else { return nil }
        (uiView as? NativeTextView)?.ensureFullLayout()
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: ceil(height))
    }

    public func updateUIView(_ uiView: UITextView, context: Context) {
        guard let textView = uiView as? NativeTextView else { return }
        let coordinator = context.coordinator
        coordinator.refresh(text: $text, isWikiLinkActive: $isWikiLinkActive, onLinkClick: onLinkClick)
        coordinator.onSlashCommandChange = onSlashCommandChange
        coordinator.onInlinePreviewKey = onInlinePreviewKey
        slashCommandProxy?.coordinator = coordinator
        textView.onTaskMarkerMenu = onTaskMarkerMenu
        textView.onCalloutMenu = onCalloutMenu
        textView.onTaskCheckboxToggle = onTaskCheckboxToggle
        textView.onTagClick = onTagClick
        textView.onPasteImage = onPasteImage
        textView.imageEmbedMenu = imageEmbedMenu
        textView.setHeader(header)
        textView.setKeyboardBar(keyboardBar)
        textView.bodyInsets = insets

        let isNodeSwitch = coordinator.documentId != documentId
        if isNodeSwitch { coordinator.configuration.calloutFoldOverrides = [:] }

        // Input behaviour, extensions, services and theme, as the macOS wrapper syncs them.
        textView.configuration.lists = configuration.lists
        coordinator.configuration.lists = configuration.lists
        if configuration.extensionRegistry.fingerprint != coordinator.configuration.extensionRegistry.fingerprint {
            coordinator.configuration.extensions = configuration.extensions
            textView.configuration.extensions = configuration.extensions
            coordinator.configuration.directives = configuration.directives
            textView.configuration.directives = configuration.directives
            coordinator.configuration.directiveSettings = configuration.directiveSettings
            textView.configuration.directiveSettings = configuration.directiveSettings
            coordinator.cachedParsedDocument = nil
            restyleAll(textView, coordinator)
        }
        let newImageFingerprint = configuration.services.images.fingerprint()
        let newWikiFingerprint = configuration.services.wikiLinks.fingerprint()
        if newImageFingerprint != coordinator.lastImageFingerprint || newWikiFingerprint != coordinator.lastWikiFingerprint {
            let imageChanged = newImageFingerprint != coordinator.lastImageFingerprint
            coordinator.lastImageFingerprint = newImageFingerprint
            coordinator.lastWikiFingerprint = newWikiFingerprint
            coordinator.configuration.services = configuration.services
            textView.configuration.services = configuration.services
            if imageChanged, let layoutManager = textView.textLayoutManager {
                layoutManager.invalidateLayout(for: layoutManager.documentRange)
            }
            restyleAll(textView, coordinator)
        }
        if configuration.theme != coordinator.configuration.theme {
            coordinator.configuration.theme = configuration.theme
            textView.configuration.theme = configuration.theme
            coordinator.configuration.taskCheckbox = configuration.taskCheckbox
            textView.configuration.taskCheckbox = configuration.taskCheckbox
            coordinator.configuration.inlineCode = configuration.inlineCode
            textView.configuration.inlineCode = configuration.inlineCode
            coordinator.configuration.extensions = configuration.extensions
            textView.configuration.extensions = configuration.extensions
            coordinator.configuration.callouts = configuration.callouts
            textView.configuration.callouts = configuration.callouts
            coordinator.configuration.tags = configuration.tags
            textView.configuration.tags = configuration.tags
            coordinator.configuration.services = configuration.services
            textView.configuration.services = configuration.services
            coordinator.cachedParsedDocument = nil
            configuration.theme.apply(to: textView)
            restyleAll(textView, coordinator)
            if let layoutManager = textView.textLayoutManager {
                layoutManager.invalidateLayout(for: layoutManager.documentRange)
            }
            textView.setNeedsDisplay()
        }
        textView.isEditable = isEditable
        textView.insertionPointColor = coordinator.resolvedCaretColor ?? coordinator.configuration.theme.bodyText

        let fontChanged = coordinator.fontName != fontName || coordinator.fontSize != fontSize
        if coordinator.didInitialFormatting, coordinator.lastSyncedText == text, !fontChanged, !isNodeSwitch {
            return
        }
        if fontChanged { coordinator.didInitialFormatting = false }
        if isNodeSwitch {
            if let outgoingId = coordinator.documentId {
                coordinator.scrollOffsets[outgoingId] = textView.contentOffset.y
                coordinator.undoContentSnapshots[outgoingId] = coordinator.lastSyncedText
            }
            coordinator.documentId = documentId
            coordinator.invalidateUndoIfContentDiverged(for: documentId, incomingText: text)
            coordinator.didInitialFormatting = false
            coordinator.didEnsureLayoutForCurrentDocument = false
            coordinator.resetImageEmbedState()
            coordinator.dismissSlashCommand()
        }
        let font = UIFont.named(fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
        textView.font = font
        textView.baseFont = font
        coordinator.fontName = fontName
        coordinator.fontSize = fontSize
        textView.baseTypingAttributes = baseTypingAttributes(layoutBridge: coordinator.layoutBridge)
        coordinator.rebuildTextStorageAndStyle(textView, from: text, invalidateLayout: isNodeSwitch)
        if isNodeSwitch {
            let saved = coordinator.scrollOffsets[documentId] ?? -textView.adjustedContentInset.top
            textView.setContentOffset(CGPoint(x: 0, y: saved), animated: false)
        }
        coordinator.didInitialFormatting = true
    }

    private var insets: UIEdgeInsets {
        UIEdgeInsets(
            top: configuration.textInsets.vertical,
            left: configuration.textInsets.horizontal,
            bottom: configuration.textInsets.vertical,
            right: configuration.textInsets.horizontal
        )
    }

    private func baseTypingAttributes(layoutBridge: LayoutBridge? = nil) -> [NSAttributedString.Key: Any] {
        let (font, paragraphStyle) = TextStylingService.makeBaseFontAndStyle(
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: layoutBridge,
            configuration: configuration
        )
        return [.font: font, .paragraphStyle: paragraphStyle, .foregroundColor: configuration.theme.bodyText]
    }

    private func restyleAll(_ textView: NativeTextView, _ coordinator: Coordinator) {
        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
        if fullRange.length > 0 { coordinator.restyleParagraphs([fullRange], in: textView) }
    }
}
#endif
