//
//  TextMenu.swift
//  MarkdownEngine
//
//  Fork: a right-click on text that no other menu takes goes to
//  `NativeTextViewWrapper.onTextMenu` instead of the system menu. The request
//  says what is under the pointer and what the selection already is, and
//  carries the edits the embedder's menu rows run, through the editor's own
//  formatting, input and paste paths. macOS only.
//

#if os(macOS)
import AppKit
import MarkdownEngineSyntax

/// Fork: what a line is, by its marker.
public enum TextMenuBlockKind: Equatable, Sendable {
    /// `#` to `######`.
    case heading(Int)
    /// `-`, `*` or `+`.
    case bullet
    /// `1.` or `1)`.
    case numbered
    /// A list item with a box (`- [ ]`).
    case task
    /// `>`.
    case quote
    /// Anything else.
    case body
}

/// Fork: a link under the pointer.
public struct TextMenuLink: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// `[[target#heading|alias]]`.
        case wiki
        /// `[label](url)` or `<url>`.
        case markdown
    }

    public let kind: Kind
    /// The whole link in the editor's text (a wiki link is displayed without its `|alias`, so its length can differ from `source`).
    public let range: NSRange
    /// The link as written: `[[Note#Part|alias]]`, `[label](url)`.
    public let source: String
    /// A wiki link's target (empty for the same file), or a markdown link's destination.
    public let target: String
    /// A wiki link's `#heading`.
    public let heading: String?
    /// A wiki link's `#^block`.
    public let block: String?
    /// A wiki link's `|alias`, or a markdown link's label.
    public let alias: String?
}

/// Fork: a right-click on text, delivered through ``NativeTextViewWrapper/onTextMenu``. The right-click moves the caret
/// onto the pointer unless it is inside the selection. The actions edit the text as the editor's own commands do and
/// leave the keyboard where it was; call ``close()`` when the menu closes.
public struct TextMenuRequest {
    /// The selected range, or the caret (length 0).
    public let selection: NSRange
    /// The selected text, empty for a caret.
    public let selectedText: String
    public var hasSelection: Bool { selection.length > 0 }
    /// The link under the pointer, if any.
    public let link: TextMenuLink?
    /// The formats the selection, or the word at the caret, is already in.
    public let activeFormats: Set<MarkdownFormat>
    /// The kind of the line the selection starts on.
    public let blockKind: TextMenuBlockKind
    /// The line above the selection's line is blank, or there is none.
    public let followsBlankLine: Bool
    /// The pointer in screen coordinates, to anchor the menu.
    public let anchorRect: CGRect

    let toggleFormatAction: @MainActor (MarkdownFormat) -> Void
    let setBlockKindAction: @MainActor (TextMenuBlockKind) -> Void
    let insertAction: @MainActor (String, NSRange, Bool) -> Void
    let replaceSelectionAction: @MainActor (String) -> Void
    let clipboardAction: @MainActor (Clipboard) -> Void
    let closeAction: @MainActor () -> Void

    enum Clipboard { case cut, copy, paste, pasteAsPlainText, selectAll }

    /// Toggles `format` on the selection, or on the word at the caret.
    @MainActor public func toggleFormat(_ format: MarkdownFormat) { toggleFormatAction(format) }

    /// Makes the line `kind`; the line's current kind makes it body text. Only the marker changes.
    @MainActor public func setBlockKind(_ kind: TextMenuBlockKind) { setBlockKindAction(kind) }

    /// Replaces the current selection with `text` as one undo step and selects `selection` (relative to `text`), as a
    /// slash command's insert does; a result that leaves the caret straight after `[[` or `![[` opens that link or
    /// embed query. With `asBlock`, `text` starts on its own line, and what follows the selection on its line moves to the next.
    @MainActor public func insert(_ text: String, selecting selection: NSRange, asBlock: Bool) {
        insertAction(text, selection, asBlock)
    }

    /// Replaces the range the request was made for with `text`, one undo step, the caret after it. Does nothing once the text
    /// there has changed.
    @MainActor public func replaceSelection(_ text: String) { replaceSelectionAction(text) }

    @MainActor public func cut() { clipboardAction(.cut) }
    @MainActor public func copy() { clipboardAction(.copy) }
    @MainActor public func paste() { clipboardAction(.paste) }
    /// Pastes the pasteboard's text as it is, with no markdown conversion, as one undo step.
    @MainActor public func pasteAsPlainText() { clipboardAction(.pasteAsPlainText) }
    @MainActor public func selectAll() { clipboardAction(.selectAll) }

    /// Call when the menu closes: the keyboard returns to the editor.
    @MainActor public func close() { closeAction() }
}

extension TextMenuBlockKind {

    /// The kind of `line` (without its line ending) and its marker: the range after the indentation through the blanks
    /// after the marker (empty for body text), relative to the line.
    static func parse(_ line: NSString) -> (kind: TextMenuBlockKind, marker: NSRange) {
        let length = line.length
        func isBlank(_ index: Int) -> Bool { line.character(at: index) == 0x20 || line.character(at: index) == 0x09 }
        func skipBlanks(_ index: Int) -> Int {
            var index = index
            while index < length, isBlank(index) { index += 1 }
            return index
        }
        let start = skipBlanks(0)
        func result(_ kind: TextMenuBlockKind, markerEnd: Int) -> (TextMenuBlockKind, NSRange) {
            (kind, NSRange(location: start, length: skipBlanks(markerEnd) - start))
        }
        guard start < length else { return (.body, NSRange(location: start, length: 0)) }
        let first = line.character(at: start)
        switch first {
        case 0x23:
            var end = start
            while end < length, line.character(at: end) == 0x23 { end += 1 }
            if end - start <= 6, end == length || isBlank(end) { return result(.heading(end - start), markerEnd: end) }
        case 0x3E:
            var end = start
            while end < length, line.character(at: end) == 0x3E || isBlank(end) { end += 1 }
            return (.quote, NSRange(location: start, length: end - start))
        case 0x2D, 0x2A, 0x2B:
            guard start + 1 == length || isBlank(start + 1) else { break }
            if let box = TaskMarker.box(inTextAfterListMarker: line.substring(from: start + 1)) {
                return result(.task, markerEnd: start + 1 + box.offset + 2)
            }
            return result(.bullet, markerEnd: start + 1)
        case 0x30...0x39:
            var end = start
            while end < length, (0x30...0x39).contains(line.character(at: end)) { end += 1 }
            if end - start <= 9, end < length, line.character(at: end) == 0x2E || line.character(at: end) == 0x29,
               end + 1 == length || isBlank(end + 1) {
                return result(.numbered, markerEnd: end + 1)
            }
        default:
            break
        }
        return (.body, NSRange(location: start, length: 0))
    }

    /// The marker text for the kind.
    var marker: String {
        switch self {
        case .heading(let level): String(repeating: "#", count: max(1, min(level, 6))) + " "
        case .bullet: "- "
        case .numbered: "1. "
        case .task: "- [ ] "
        case .quote: "> "
        case .body: ""
        }
    }
}

extension NativeTextView {

    /// The request for a right-click `event` on text; moves the caret to the pointer unless the pointer is in the selection.
    func textMenuRequest(for event: NSEvent) -> TextMenuRequest? {
        guard let coordinator = delegate as? NativeTextViewCoordinator else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let text = string as NSString
        let index = min(characterIndexForInsertion(at: point), text.length)
        var selection = selectedRange()
        if !(selection.length > 0 && index >= selection.location && index <= NSMaxRange(selection)) {
            selection = NSRange(location: index, length: 0)
            setSelectedRange(selection)
        }

        var formatRange = selection
        if selection.length == 0, let word = coordinator.wordRange(at: selection.location, in: text) { formatRange = word }
        var formats = Set<MarkdownFormat>()
        if coordinator.isSelectionBold(in: text, range: formatRange) { formats.insert(.bold) }
        if coordinator.isSelectionItalic(in: text, range: formatRange) { formats.insert(.italic) }
        if coordinator.isSelectionStrikethrough(in: text, range: formatRange) { formats.insert(.strikethrough) }
        if coordinator.isSelectionHighlight(in: text, range: formatRange) { formats.insert(.highlight) }
        if coordinator.isSelectionInlineCode(in: text, range: formatRange) { formats.insert(.inlineCode) }

        let lineRange = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let line = text.substring(with: lineRange).trimmingCharacters(in: .newlines) as NSString
        var followsBlank = true
        if lineRange.location > 0 {
            let above = text.lineRange(for: NSRange(location: lineRange.location - 1, length: 0))
            followsBlank = text.substring(with: above).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let selectedText = text.substring(with: selection)

        return TextMenuRequest(
            selection: selection, selectedText: selectedText,
            link: coordinator.textMenuLink(at: index, in: text), activeFormats: formats,
            blockKind: TextMenuBlockKind.parse(line).kind, followsBlankLine: followsBlank,
            anchorRect: menuAnchorRect(forViewRect: CGRect(x: point.x, y: point.y, width: 1, height: 1)),
            toggleFormatAction: { [weak self] in self?.toggleForTextMenu($0) },
            setBlockKindAction: { [weak self] in self?.setBlockKind($0) },
            insertAction: { [weak self] in self?.insertForTextMenu($0, selecting: $1, asBlock: $2) },
            replaceSelectionAction: { [weak self] replacement in
                guard let self else { return }
                let current = self.string as NSString
                guard NSMaxRange(selection) <= current.length, current.substring(with: selection) == selectedText else { return }
                self.replaceForTextMenu(selection, with: replacement,
                                        selecting: NSRange(location: (replacement as NSString).length, length: 0), actionName: "Replace")
            },
            clipboardAction: { [weak self] action in
                guard let self else { return }
                switch action {
                case .cut: self.cut(nil)
                case .copy: self.copy(nil)
                case .paste: self.paste(nil)
                case .pasteAsPlainText:
                    guard let pasted = NSPasteboard.general.string(forType: .string), !pasted.isEmpty else { return }
                    self.insertPasted(pasted, replacementRange: self.selectedRange())
                case .selectAll: self.selectAll(nil)
                }
            },
            closeAction: { [weak self] in
                guard let self, let window = self.window, window.firstResponder !== self else { return }
                window.makeFirstResponder(self)
            }
        )
    }

    private func toggleForTextMenu(_ format: MarkdownFormat) {
        guard let coordinator = delegate as? NativeTextViewCoordinator else { return }
        // Highlight wraps a selection only, so a caret in a word selects the word first.
        if format == .highlight, selectedRange().length == 0,
           let word = coordinator.wordRange(at: selectedRange().location, in: string as NSString) {
            setSelectedRange(word)
        }
        coordinator.toggle(format)
    }

    /// Changes the marker of the selection's first line to `kind`'s, or removes it when the line already is `kind`.
    private func setBlockKind(_ kind: TextMenuBlockKind) {
        let text = string as NSString
        let selection = selectedRange()
        let lineRange = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let line = text.substring(with: lineRange).trimmingCharacters(in: .newlines) as NSString
        let current = TextMenuBlockKind.parse(line)
        let new = current.kind == kind ? TextMenuBlockKind.body.marker : kind.marker
        let marker = NSRange(location: lineRange.location + current.marker.location, length: current.marker.length)
        guard text.substring(with: marker) != new else { return }
        let delta = (new as NSString).length - marker.length
        let contentStart = NSMaxRange(marker) + delta
        func moved(_ location: Int) -> Int { location >= NSMaxRange(marker) ? location + delta : contentStart }
        let start = moved(selection.location), end = moved(NSMaxRange(selection))
        replaceForTextMenu(marker, with: new, selecting: nil, actionName: "Paragraph")
        setSelectedRange(NSRange(location: start, length: end - start))
    }

    private func insertForTextMenu(_ insertion: String, selecting selection: NSRange, asBlock: Bool) {
        let text = string as NSString
        let range = selectedRange()
        var insertion = insertion, selection = selection
        if asBlock {
            let lineStart = text.lineRange(for: NSRange(location: range.location, length: 0)).location
            if !text.substring(with: NSRange(location: lineStart, length: range.location - lineStart)).allSatisfy(\.isWhitespace) {
                insertion = "\n" + insertion
                selection.location += 1
            }
            var contentsEnd = 0
            text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: NSMaxRange(range), length: 0))
            if contentsEnd > NSMaxRange(range),
               !text.substring(with: NSRange(location: NSMaxRange(range), length: contentsEnd - NSMaxRange(range))).allSatisfy(\.isWhitespace) {
                insertion += "\n"
            }
        }
        replaceForTextMenu(range, with: insertion, selecting: selection, actionName: "Insert")
        if let coordinator = delegate as? NativeTextViewCoordinator {
            coordinator.openLinkQuery(endingAt: range.location + selection.location + selection.length, in: self)
        }
    }

    /// Replaces `range` as one undo step; selects `selection` (relative to `replacement`) when given.
    private func replaceForTextMenu(_ range: NSRange, with replacement: String, selecting selection: NSRange?, actionName: String) {
        let coordinator = delegate as? NativeTextViewCoordinator
        breakUndoCoalescing()
        coordinator?.isProgrammaticEdit = true
        defer { coordinator?.isProgrammaticEdit = false }
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        optionalTextStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        undoManager?.setActionName(actionName)
        breakUndoCoalescing()
        if let selection { setSelectedRange(NSRange(location: range.location + selection.location, length: selection.length)) }
    }
}

extension NativeTextViewCoordinator {

    /// The link whose source holds `index`, as it reads in the editor's text.
    func textMenuLink(at index: Int, in text: NSString) -> TextMenuLink? {
        for token in parsedDocument(for: text as String).tokens where token.range.location <= index && index < NSMaxRange(token.range) {
            switch token.kind {
            case .wikiLink:
                var inner = text.substring(with: token.contentRange)
                let suffix = textView?.optionalTextStorage?.attribute(.wikiLinkID, at: token.contentRange.location, effectiveRange: nil) as? String
                    ?? wikiLinkID(for: token.range)
                if let suffix, !suffix.isEmpty { inner += "|" + suffix }
                guard let parts = WikiLinkParts(inner: inner) else { return nil }
                return TextMenuLink(kind: .wiki, range: token.range, source: "[[\(inner)]]", target: parts.target,
                                    heading: parts.heading, block: parts.block, alias: parts.alias)
            case .link:
                let url: String
                if text.character(at: token.range.location) == 0x3C {
                    url = text.substring(with: token.contentRange)
                } else if let destination = InlineParser.linkDestination(
                    text, from: NSMaxRange(token.contentRange) + 2, end: NSMaxRange(token.range)) {
                    url = text.substring(with: destination.range)
                } else {
                    return nil
                }
                return TextMenuLink(kind: .markdown, range: token.range, source: text.substring(with: token.range), target: url,
                                    heading: nil, block: nil, alias: text.substring(with: token.contentRange))
            default:
                continue
            }
        }
        return nil
    }
}
#endif
