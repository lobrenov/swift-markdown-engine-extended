//
//  NativeTextViewIOS.swift
//  MarkdownEngine
//
//  The iOS editor: a TextKit 2 `UITextView` with the state the shared
//  styling, input and layout code reads from the macOS `NativeTextView`.
//

#if os(iOS)
import SwiftUI
import UIKit

final class NativeTextView: UITextView {
    var configuration: MarkdownEditorConfiguration = .default

    /// The pairs whose closers typing steps over (`MarkdownAutoPairs`). Every applied edit
    /// moves them; undo and redo forget them.
    var autoPairs: [AutoPair] = []

    weak var layoutBridge: LayoutBridge?
    var baseFont: UIFont = .systemFont(ofSize: UIFont.systemFontSize)

    /// See ``NativeTextViewWrapper/onTaskMarkerMenu``.
    var onTaskMarkerMenu: ((TaskMarkerMenuRequest) -> Void)?
    /// See ``NativeTextViewWrapper/onCalloutMenu``.
    var onCalloutMenu: ((CalloutMenuRequest) -> Void)?
    /// See ``NativeTextViewWrapper/onTaskCheckboxToggle``.
    var onTaskCheckboxToggle: ((Character) -> Void)?
    /// See ``NativeTextViewWrapper/onTagClick``.
    var onTagClick: ((String) -> Void)?
    /// See ``NativeTextViewWrapper/onPasteImage``.
    var onPasteImage: ((UIPasteboard) -> String?)?
    /// The title line location of the callout whose menu is open.
    var calloutMenuTarget: Int?
    /// See ``NativeTextViewWrapper/imageEmbedMenu``.
    var imageEmbedMenu: ((ImageEmbedRequest) -> UIMenu?)?
    /// The `![[ ]]` of the selected image, and of the image whose menu is open (`ImageEmbedHits.swift`).
    var selectedImageEmbed: NSRange?
    var imageEmbedMenuTarget: NSRange?
    /// Skips the next scroll-to-caret, after an edit that places the caret itself.
    var suppressAutoRevealOnce = false
    /// What the selection and text delegates are reacting to: typing or a tap.
    var inputKind: EditorInputKind = .other

    /// The attributes typed text starts with: the body font and paragraph style,
    /// so a heading's style never carries into the next line.
    var baseTypingAttributes: [NSAttributedString.Key: Any]?

    /// The embedder's header, above the text; it scrolls with it.
    private var headerHost: UIHostingController<AnyView>?
    private var headerHeight: CGFloat = 0
    /// The vertical text inset before the header's height is added.
    var bodyInsets = UIEdgeInsets.zero {
        didSet { applyInsets() }
    }

    init() {
        let layoutManager = NSTextLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.textContainer = container
        let contentStorage = NSTextContentStorage()
        contentStorage.addTextLayoutManager(layoutManager)
        super.init(frame: .zero, textContainer: container)
        container.textView = self
        gestures.textView = self
        for recognizer in [gestures.tap, gestures.press] {
            recognizer.delegate = gestures
            addGestureRecognizer(recognizer)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidShow),
                                               name: UIResponder.keyboardDidShowNotification, object: nil)
    }

    private let gestures = EditorGestures()
    /// Fork: shows the image menu (`ImageEmbedMenuButton.swift`).
    var imageMenuButton: UIButton?

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var coordinator: NativeTextViewCoordinator? { delegate as? NativeTextViewCoordinator }

    /// Each document keeps its own undo stack (see `NativeTextViewCoordinator.undoManager(forDocument:)`).
    override var undoManager: UndoManager? {
        coordinator.map { $0.undoManager(forDocument: $0.documentId) } ?? super.undoManager
    }

    /// The caret's syntax shows only while the keyboard is up (`revealsSyntax`).
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { coordinator?.editingFocusDidChange(in: self) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { coordinator?.editingFocusDidChange(in: self) }
        return resigned
    }

    override var typingAttributes: [NSAttributedString.Key: Any] {
        get { baseTypingAttributes ?? super.typingAttributes }
        set { super.typingAttributes = baseTypingAttributes ?? newValue }
    }

    // MARK: Input kind

    override func insertText(_ text: String) {
        inputKind = .key
        defer { inputKind = .other }
        super.insertText(text)
    }

    override func deleteBackward() {
        inputKind = .key
        defer { inputKind = .other }
        super.deleteBackward()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        inputKind = .click
        super.touchesEnded(touches, with: event)
        DispatchQueue.main.async { [weak self] in self?.inputKind = .other }
    }

    // MARK: Hardware keyboard

    override var keyCommands: [UIKeyCommand]? {
        var commands = [UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(outdent))]
        // Only a query: the inline preview's state stays set while the caret is in a link or image's source, and
        // iOS has no fallback for ↑/↓ that nothing consumes.
        if coordinator?.completionOwner == .query {
            for input in [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, UIKeyCommand.inputEscape, "\r"] {
                let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(completionKey(_:)))
                command.wantsPriorityOverSystemBehavior = true
                commands.append(command)
            }
        }
        return commands
    }

    @objc func outdent() {
        _ = coordinator?.handleBacktab(self)
    }

    /// ↑/↓ move through an open query's menu, ↵ confirms, esc closes, as on macOS (`+Completion`).
    @objc private func completionKey(_ command: UIKeyCommand) {
        guard let coordinator else { return }
        let key: InlinePreviewKey = switch command.input {
        case UIKeyCommand.inputUpArrow: .moveUp
        case UIKeyCommand.inputDownArrow: .moveDown
        case UIKeyCommand.inputEscape: .cancel
        default: .confirm
        }
        if !coordinator.routeCompletionKey(key), key == .confirm {
            insertText("\n")
        }
    }

    // MARK: Taps and presses

    /// A tap on a task box toggles it; on a drawn tag, goes to `onTagClick`; on a `[[ ]]` link, to `onLinkClick`; on a foldable callout's title row
    /// (outside its text), folds it. Anywhere else it puts the caret there, as the tap that brings up the keyboard
    /// must: UIKit's finds the caret's place after the focus restyles the text, which puts it at the end.
    func handleTap(at point: CGPoint) {
        if let hit = taskCheckboxHit(atViewPoint: point) {
            toggleTaskCheckbox(hit)
            onTaskCheckboxToggle?(hit.marker)
        } else if let onTagClick, let tag = tagHit(atViewPoint: point) {
            onTagClick(tag)
        } else if let target = wikiLinkHit(atViewPoint: point) {
            coordinator?.onLinkClick?(target)
        } else if let hit = calloutTitleHit(atViewPoint: point), toggleCalloutFold(hit) {
            return
        } else {
            let location = characterIndex(atViewPoint: point)
            if !isFirstResponder { becomeFirstResponder() }
            setSelectedRange(NSRange(location: location, length: 0))
        }
    }

    /// Press and hold on a task box, a callout title line or a drawn image opens its menu.
    func handlePress(at point: CGPoint) {
        if let onTaskMarkerMenu, let hit = taskCheckboxHit(atViewPoint: point) {
            onTaskMarkerMenu(taskMarkerMenuRequest(for: hit))
        } else if let onCalloutMenu, let hit = calloutTitleHit(atViewPoint: point) {
            showCalloutMenu(for: hit, onCalloutMenu)
        } else if let hit = imageEmbedHit(atViewPoint: point), let menu = imageEmbedMenu(for: hit.range) {
            showImageEmbedMenu(menu, at: point)
        }
    }

    fileprivate func takesTap(at point: CGPoint) -> Bool {
        if taskCheckboxHit(atViewPoint: point) != nil { return true }
        if onTagClick != nil, tagHit(atViewPoint: point) != nil { return true }
        if coordinator?.onLinkClick != nil, wikiLinkHit(atViewPoint: point) != nil { return true }
        if let hit = calloutTitleHit(atViewPoint: point), hit.header.fold.length == 1 { return true }
        return isEditable && !isFirstResponder
    }

    /// Fork: the target of the `[[ ]]` link whose text is under a point. While the caret touches the link (with
    /// the keyboard up), a tap there places the caret instead.
    func wikiLinkHit(atViewPoint point: CGPoint) -> String? {
        guard let storage = optionalTextStorage, storage.length > 0 else { return nil }
        let index = characterIndex(atViewPoint: point)
        for location in [index, index - 1] where location >= 0 && location < storage.length {
            var range = NSRange()
            guard let target = storage.attribute(.link, at: location, effectiveRange: &range) as? String,
                  !isFirstResponder || selectedRange.location < range.location - 2
                    || selectedRange.location > NSMaxRange(range) + 2,
                  let start = position(from: beginningOfDocument, offset: range.location),
                  let end = position(from: start, offset: range.length),
                  let textRange = textRange(from: start, to: end) else { continue }
            if selectionRects(for: textRange).contains(where: { $0.rect.insetBy(dx: 0, dy: -4).contains(point) }) {
                return target
            }
        }
        return nil
    }

    func takesPress(at point: CGPoint) -> Bool {
        (onTaskMarkerMenu != nil && taskCheckboxHit(atViewPoint: point) != nil)
            || (onCalloutMenu != nil && calloutTitleHit(atViewPoint: point) != nil)
            || (imageEmbedMenu != nil && imageEmbedHit(atViewPoint: point) != nil)
    }

    // MARK: Layout

    /// Lays out the whole document, so `sizeThatFits` measures all of it.
    func ensureFullLayout() {
        guard let layoutManager = textLayoutManager else { return }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
    }

    /// Lays out the visible part of the document, as AppKit's `ensureLayout` would.
    func ensureVisibleLayout() {
        guard let layoutManager = textLayoutManager,
              let viewport = layoutManager.textViewportLayoutController.viewportRange else { return }
        layoutManager.ensureLayout(for: viewport)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutHeader()
        // Fork: images fit the width once it's known.
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.coordinator?.restyleImageEmbedsIfWidthChanged(in: self)
            }
        }
    }

    // MARK: Fork: image paste

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), onPasteImage != nil, isEditable, UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    /// An image on the pasteboard goes to `onPasteImage`, and its embed goes on its own line.
    override func paste(_ sender: Any?) {
        guard let onPasteImage, UIPasteboard.general.hasImages, let embed = onPasteImage(.general), !embed.isEmpty else {
            return super.paste(sender)
        }
        let selection = selectedRange
        let text = self.text as NSString
        let before = selection.location > 0 && text.character(at: selection.location - 1) != 0x0A ? "\n" : ""
        let after = NSMaxRange(selection) < text.length && text.character(at: NSMaxRange(selection)) != 0x0A ? "\n" : ""
        replaceCharacters(in: selection, with: before + embed + after)
    }

    // MARK: Keyboard bar

    private var keyboardBarHost: UIHostingController<AnyView>?

    func setKeyboardBar(_ bar: AnyView?) {
        guard let bar else {
            guard keyboardBarHost != nil else { return }
            keyboardBarHost = nil
            inputAccessoryView = nil
            if isFirstResponder { reloadInputViews() }
            return
        }
        if let keyboardBarHost {
            keyboardBarHost.rootView = bar
            fitKeyboardBar()
            return
        }
        let host = UIHostingController(rootView: bar)
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        let container = KeyboardBarContainer(frame: CGRect(x: 0, y: 0, width: 0, height: 52))
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.frame = container.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(host.view)
        keyboardBarHost = host
        inputAccessoryView = container
        fitKeyboardBar()
        if isFirstResponder { reloadInputViews() }
    }

    /// Fork: makes the bar's container as tall as its content, which can grow above the bar (a list of
    /// choices), and keeps the caret above it.
    private func fitKeyboardBar() {
        guard let host = keyboardBarHost, let container = inputAccessoryView as? KeyboardBarContainer else { return }
        let width = container.bounds.width > 0 ? container.bounds.width : window?.bounds.width ?? 390
        let height = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height.rounded(.up)
        guard height != container.height else { return }
        container.height = height
        revealCaretAboveKeyboardBarSoon()
    }

    /// How far the caret stays above the keyboard bar.
    private static let keyboardBarMargin: CGFloat = 12

    @objc private func keyboardDidShow() {
        revealCaretAboveKeyboardBar()
    }

    private var isRevealPending = false

    /// After the caret moves or the text changes, once UIKit has scrolled the caret into view. Requests made
    /// before it runs share it.
    func revealCaretAboveKeyboardBarSoon() {
        guard !isRevealPending else { return }
        isRevealPending = true
        DispatchQueue.main.async { [weak self] in
            self?.isRevealPending = false
            self?.revealCaretAboveKeyboardBar()
        }
    }

    /// Scrolls the text, or the scroll view it sits in, so the caret clears the keyboard bar, which floats over
    /// the text above the keyboard.
    func revealCaretAboveKeyboardBar() {
        guard isFirstResponder, let bar = keyboardBarHost?.view, let barScreen = bar.window?.screen,
              let screen = window?.screen, let caret = selectedTextRange?.end else { return }
        var view: UIView? = isScrollEnabled ? self : superview
        while let candidate = view, !(candidate is UIScrollView) { view = candidate.superview }
        guard let scrollView = view as? UIScrollView else { return }
        let caretRect = convert(caretRect(for: caret), to: screen.coordinateSpace)
        let barTop = bar.convert(bar.bounds, to: barScreen.coordinateSpace).minY
        let overlap = caretRect.maxY + Self.keyboardBarMargin - barTop
        guard overlap > 0 else { return }
        let maxOffset = scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height
        let y = min(scrollView.contentOffset.y + overlap, max(maxOffset, scrollView.contentOffset.y))
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: y), animated: false)
    }

    // MARK: Header

    func setHeader(_ header: AnyView?) {
        guard let header else {
            headerHost?.view.removeFromSuperview()
            headerHost = nil
            headerHeight = 0
            applyInsets()
            return
        }
        if let headerHost {
            headerHost.rootView = header
        } else {
            let host = UIHostingController(rootView: header)
            host.view.backgroundColor = .clear
            host.sizingOptions = .intrinsicContentSize
            addSubview(host.view)
            headerHost = host
        }
        setNeedsLayout()
    }

    private func layoutHeader() {
        guard let view = headerHost?.view else { return }
        let width = bounds.width
        guard width > 0 else { return }
        let height = ceil(view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        if abs(height - headerHeight) > 0.5 {
            headerHeight = height
            applyInsets()
        }
    }

    func applyInsets() {
        var insets = bodyInsets
        insets.top += headerHeight + leadingCalloutPadding
        if textContainerInset != insets { textContainerInset = insets }
    }
}
/// The editor's own tap and press, which the text view's gestures wait for. The tap begins over a task box, a link or
/// a callout title line, and anywhere while the editor doesn't have the keyboard; the press begins over a task box, a
/// callout title line or an image. Everywhere else the text view behaves as usual.
private final class EditorGestures: NSObject, UIGestureRecognizerDelegate {
    weak var textView: NativeTextView?
    lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
    lazy var press: UILongPressGestureRecognizer = {
        let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
        press.minimumPressDuration = 0.4
        return press
    }()

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        textView?.handleTap(at: recognizer.location(in: textView))
    }

    @objc private func pressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        textView?.handlePress(at: recognizer.location(in: textView))
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let textView else { return false }
        let point = recognizer.location(in: textView)
        return recognizer === tap ? textView.takesTap(at: point) : textView.takesPress(at: point)
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        other.view === textView && other !== tap && other !== press
    }
}

/// Fork: the keyboard bar's container. The keyboard sizes it by its intrinsic height.
private final class KeyboardBarContainer: UIView {
    var height: CGFloat = 52 {
        didSet { if height != oldValue { invalidateIntrinsicContentSize() } }
    }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: height) }
}
#endif
