//
//  NativeTextViewCoordinatorIOS.swift
//  MarkdownEngine
//
//  The UITextViewDelegate methods. Keystrokes and selection changes go to the
//  shared path in `+TextDelegate.swift`.
//

#if os(iOS)
import UIKit
import MarkdownEngineSyntax

extension NativeTextViewCoordinator: UITextViewDelegate {
    public func textViewDidChange(_ textView: UITextView) {
        textDidChange(in: textView)
        (textView as? NativeTextView)?.revealCaretAboveKeyboardBarSoon()
    }

    public func textViewDidChangeSelection(_ textView: UITextView) {
        selectionDidChange(in: textView)
        (textView as? NativeTextView)?.revealCaretAboveKeyboardBarSoon()
    }

    public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        let allowed = shouldChangeText(in: textView, affectedCharRange: range, replacementString: text)
        // Fork: an allowed edit moves the auto-closed pairs, as the macOS text view's `shouldChangeText` does.
        if allowed, let native = textView as? NativeTextView, !native.autoPairs.isEmpty {
            if textView.undoManager?.isUndoing == true || textView.undoManager?.isRedoing == true {
                native.autoPairs = []
            } else {
                native.autoPairs = MarkdownAutoPairs.map(native.autoPairs, replacing: range, with: text.utf16.count)
            }
        }
        return allowed
    }

    /// macOS turns autocorrection off inside code; iOS keeps the keyboard's own settings.
    func updateAutocorrectSettings(
        _ textView: UITextView,
        caretLocation: Int,
        codeTokens: [MarkdownToken]? = nil,
        latexTokens: [MarkdownToken]? = nil,
        allTokens: [MarkdownToken]? = nil
    ) {}

    /// macOS overlays copy buttons on code blocks; iOS has none.
    func updateCodeBlockSelection(textView: UITextView, parsed: ParsedDocument? = nil) {}
}
#endif
