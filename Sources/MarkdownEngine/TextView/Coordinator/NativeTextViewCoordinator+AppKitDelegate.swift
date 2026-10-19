//
//  NativeTextViewCoordinator+AppKitDelegate.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  The NSTextViewDelegate methods. Keystrokes and selection changes go to the
//  shared path in `+TextDelegate.swift`; link clicks, key commands and the
//  typing-attributes shim that keeps a heading's paragraph style off the
//  trailing extra-line fragment are AppKit's own.
//

#if os(macOS)
import AppKit

extension NativeTextViewCoordinator: NSTextViewDelegate {
    /// Supplies a per-document `UndoManager` to the text view.
    ///
    /// AppKit reuses one `NSTextView` across every open document, so the built-in
    /// view-wide undo manager would blend files together (and used to be wiped on
    /// each switch). Returning a manager keyed on the current `documentId` gives
    /// each file its own undo stack that survives switching away and back.
    /// Returning the *same* instance for a given document on every call is
    /// required — a fresh manager per call breaks undo.
    public func undoManager(for view: NSTextView) -> UndoManager? {
        if let shared = undoManagerOverride?() { return shared }
        return undoManager(forDocument: documentId)
    }

    /// Fork: on macOS 27 a TextKit 2 NSTextView doesn't post NSTextDidChangeNotification for
    /// undo or redo (TextKit 1 does), so the text changed on screen but the binding never heard.
    /// When the undo or redo is over and textDidChange didn't run for it, run it now.
    @objc func undoManagerDidUndoOrRedo(_ notification: Notification) {
        defer { sawUndoRedoTextChange = false }
        guard !sawUndoRedoTextChange, let textView, notification.object as? UndoManager === textView.undoManager else { return }
        // Without exactly one tracked edit the range can't be trusted; nil makes the wiki sync rebuild.
        if pendingEditCount != 1 { pendingEditedRange = nil }
        isReplayingUndoRedo = true
        defer { isReplayingUndoRedo = false }
        textDidChange(in: textView)
    }

    /// Force base typingAttributes on every change so AppKit's auto-inheritance
    /// can't bleed a heading paragraphStyle into the trailing extra-line
    /// fragment's metrics.
    public func textView(
        _ textView: NSTextView,
        shouldChangeTypingAttributes oldTypingAttributes: [String: Any],
        toAttributes newTypingAttributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        let (baseFont, baseParagraphStyle) = TextStylingService.makeBaseFontAndStyle(
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: layoutBridge,
            configuration: configuration
        )
        var result = newTypingAttributes
        if let alignment = paragraphAlignment, let aligned = baseParagraphStyle.mutableCopy() as? NSMutableParagraphStyle {
            aligned.alignment = alignment
            result[.paragraphStyle] = aligned
        } else {
            result[.paragraphStyle] = baseParagraphStyle
        }
        result[.font] = baseFont
        result[.foregroundColor] = configuration.theme.bodyText
        return result
    }

    public func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView else { return }
        textDidChange(in: tv)
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView else { return }
        selectionDidChange(in: tv)
    }

    public func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        shouldChangeText(in: textView, affectedCharRange: affectedCharRange, replacementString: replacementString)
    }

    public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Raw mode: default key handling (no ⇧⇥ outdent, no preview routing).
        if configuration.rawSourceMode { return false }
        // Fork: ↑/↓/↵/⇥/esc drive an open slash menu.
        if handleSlashCommandKey(commandSelector) { return true }
        // Fork: a table cell's keys.
        if let native = textView as? NativeTextView, let cell = native.tableCell, let grid = cell.grid,
           grid.handleCommand(commandSelector, from: cell) { return true }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            return handleBacktab(textView)
        }
        // While an inline [[…]] / ![[…]] preview is open, route ↑/↓/Enter/Esc to the embedder's
        // autocomplete list (it returns true to consume the key; false → normal editor handling).
        if (isWikiLinkActive || isImageEmbedActive), let handler = onInlinePreviewKey {
            let key: InlinePreviewKey?
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)): key = .moveUp
            case #selector(NSResponder.moveDown(_:)): key = .moveDown
            case #selector(NSResponder.insertNewline(_:)): key = .confirm   // ⌘↵ → handled in performKeyEquivalent
            case #selector(NSResponder.cancelOperation(_:)): key = .cancel
            default: key = nil
            }
            if let key, handler(key) { return true }
        }
        // Fork: ↓ or ↑ from the line beside a table enters it.
        if configuration.liveTables, let native = textView as? NativeTextView, native.tableCell == nil,
           native.enterTable(from: commandSelector) { return true }
        return false
    }

    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        // Record that the delegate ran this press, so mouseDown's fallback knows
        // AppKit didn't drop the dispatch.
        (textView as? NativeTextView)?.linkClickDidFire = true
        // Edit zone: a click on the outer ~30% of a link's first/last visible char places the caret
        // just outside the markers (before '[[' / '[' , after ']]' / ')') to reveal the source for
        // editing instead of navigating. Applies to both wiki links [[…]] and web links [text](url).
        // Editable views only — read-only links must stay navigable.
        if textView.isEditable, let storage = textView.textStorage {
            var linkRange = NSRange(location: NSNotFound, length: 0)
            let editZoneMinNameLength = 3   // 1–2 char names stay fully clickable for navigation
            if storage.attribute(.link, at: charIndex, longestEffectiveRange: &linkRange,
                                 in: NSRange(location: 0, length: storage.length)) != nil,
               linkRange.length >= editZoneMinNameLength {
                // Caret lands on the token's outer markers ('[['/'[' or ']]'/')'), which carry no
                // .link, so the mouse-on-link guard in textViewDidChangeSelection doesn't suppress
                // the reveal. Web links (.link) get the same edit zone as wiki links (.wikiLink); the
                // .link attribute only spans the visible text, so without the full token range a web
                // link would drop the caret between its brackets instead of just outside them.
                let token = parsedDocument(for: textView.string).tokens
                    .first { ($0.kind == .wikiLink || $0.kind == .link) && NSLocationInRange(charIndex, $0.range) }
                let edgeFraction: CGFloat = 0.3
                let frac = clickFractionThroughGlyph(textView, charIndex: charIndex)
                if charIndex == linkRange.location, frac.map({ $0 <= edgeFraction }) ?? true {
                    let caret = token?.range.location ?? linkRange.location          // before '[[' / '['
                    textView.setSelectedRange(NSRange(location: caret, length: 0))
                    return true
                }
                if charIndex == NSMaxRange(linkRange) - 1, frac.map({ $0 >= 1 - edgeFraction }) ?? true {
                    let caret = token.map { NSMaxRange($0.range) } ?? NSMaxRange(linkRange)  // after ']]' / ')'
                    textView.setSelectedRange(NSRange(location: caret, length: 0))
                    return true
                }
            }
        }
        guard let target = WikiLinkService.resolveIdentifier(link: link, textView: textView, at: charIndex) else {
            // Web link (URL-valued): returning false lets AppKit open the URL
            // (the mouseDown fallback mirrors that). Opening a link is navigation
            // too — flag it so mouseDown restores the pre-click caret.
            (textView as? NativeTextView)?.linkClickDidNavigate = true
            return false
        }
        // Direkt deaktivieren, bevor der Navigation-Callback läuft.
        (textView as? NativeTextView)?.linkClickDidNavigate = true
        self.isWikiLinkActive = false
        DispatchQueue.main.async {
            self.onLinkClick?(target)
        }
        return true
    }

    /// Horizontal fraction (0 = leading, 1 = trailing) of the current click through the glyph at
    /// `charIndex`, or nil if unresolved. Coordinates mirror NativeTextView+CursorRects.
    private func clickFractionThroughGlyph(_ textView: NSTextView, charIndex: Int) -> CGFloat? {
        guard let event = NSApp.currentEvent,
              let tlm = textView.textLayoutManager,
              let tcm = tlm.textContentManager,
              let start = tcm.location(tlm.documentRange.location, offsetBy: charIndex),
              let end = tcm.location(start, offsetBy: 1),
              let range = NSTextRange(location: start, end: end) else { return nil }
        let viewPoint = textView.convert(event.locationInWindow, from: nil)
        let containerX = viewPoint.x - textView.textContainerOrigin.x
        var glyphFrame: CGRect?
        tlm.enumerateTextSegments(in: range, type: .standard, options: []) { _, segFrame, _, _ in
            glyphFrame = segFrame
            return false
        }
        guard let f = glyphFrame, f.width > 0 else { return nil }
        return (containerX - f.minX) / f.width
    }
}
#endif
