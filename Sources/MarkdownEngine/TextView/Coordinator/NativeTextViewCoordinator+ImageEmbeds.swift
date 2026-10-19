//
//  NativeTextViewCoordinator+ImageEmbeds.swift
//  MarkdownEngine
//
//  Fork: images fit the text container's width, which isn't known yet
//  when a document is first styled, so image paragraphs restyle as it changes.
//  With `imageEmbed.revealsSourceAtCaret` off, an image stays drawn as the
//  caret passes: the caret skips its hidden source, ⌫ after it (or ⌦ before
//  it) removes the whole `![[ ]]`, and `revealImageEmbed` shows its source.
//

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import MarkdownEngineSyntax

extension NativeTextViewCoordinator {

    /// Restyles the paragraphs of the document's image embeds when the text container's usable width has changed
    /// since they were last fitted to it.
    func restyleImageEmbedsIfWidthChanged(in textView: PlatformTextView) {
        guard let container = layoutBridge?.firstTextContainer else { return }
        let width = container.containerSize.width - container.lineFragmentPadding * 2
        guard width > 0, width < configuration.imageEmbed.unreasonableMaxWidth, width != imageEmbedLayoutWidth else { return }
        imageEmbedLayoutWidth = width
        let parsed = parsedDocument(for: textView.string)
        guard !parsed.imageEmbedTokens.isEmpty else { return }
        let text = textView.string as NSString
        _ = restyleTextView(textView, paragraphCandidates: parsed.imageEmbedTokens.map { text.paragraphRange(for: $0.range) },
                            tokens: parsed.tokens, classified: parsed.classified, blocks: parsed.blocks)
    }

    /// The drawn image embed (its source hidden) that `range` falls in or touches, from the styled text.
    func collapsedImageEmbed(touching range: NSRange, in textView: PlatformTextView) -> MarkdownToken? {
        guard !configuration.imageEmbed.revealsSourceAtCaret, let storage = textView.optionalTextStorage else { return nil }
        let parsed = parsedDocument(for: textView.string)
        return parsed.imageEmbedTokens.first { token in
            guard token.range.location != revealedImageEmbed,
                  NSIntersectionRange(token.range, range).length > 0 || NSLocationInRange(range.location, token.range)
                    || range.location == NSMaxRange(token.range),
                  NSMaxRange(token.range) <= storage.length else { return false }
            var drawn = false
            storage.enumerateAttribute(.latexImage, in: token.range) { value, _, stop in
                if value != nil { drawn = true; stop.pointee = true }
            }
            return drawn
        }
    }

    /// From every selection change: a caret inside a drawn image's hidden source moves after it, or before it when
    /// it came from after it.
    func snapCaretOutOfImageEmbed(in textView: PlatformTextView) {
        let selection = textView.currentSelectedRange
        guard selection.length == 0, let token = collapsedImageEmbed(touching: selection, in: textView),
              selection.location > token.range.location, selection.location < NSMaxRange(token.range) else { return }
        let cameFromAfter = (previousCaretLocation ?? 0) >= NSMaxRange(token.range)
        textView.setSelectedRange(NSRange(location: cameFromAfter ? token.range.location : NSMaxRange(token.range), length: 0))
    }

    /// From `shouldChangeTextIn`, for interactive edits: ⌫ right after a drawn image, or ⌦ right before it, removes
    /// its whole `![[ ]]` as one undo step. `true` when it did.
    func deleteImageEmbedIfAdjacent(_ range: NSRange, replacement: String?, in textView: PlatformTextView) -> Bool {
        guard replacement == "", range.length == 1,
              let token = collapsedImageEmbed(touching: NSRange(location: range.location, length: 0), in: textView)
                ?? collapsedImageEmbed(touching: NSRange(location: NSMaxRange(range), length: 0), in: textView),
              NSMaxRange(range) == NSMaxRange(token.range) || range.location == token.range.location else { return false }
        textView.breakUndoCoalescing()
        MarkdownLists.performEdit(textView, replace: token.range, with: "")
        textView.undoManager?.setActionName("Delete Image")
        textView.breakUndoCoalescing()
        textView.setSelectedRange(NSRange(location: token.range.location, length: 0))
        return true
    }

    /// Shows the source of the image embed at `location` and puts the caret after its `]]`. It's drawn again once the
    /// caret leaves its paragraph.
    func revealImageEmbed(at location: Int) {
        guard let textView else { return }
        let parsed = parsedDocument(for: textView.string)
        guard let token = parsed.imageEmbedTokens.first(where: { NSLocationInRange(location, $0.range) }) else { return }
        revealedImageEmbed = token.range.location
        textView.setSelectedRange(NSRange(location: NSMaxRange(token.range), length: 0))
        let text = textView.string as NSString
        activeTokenIndices = activeTokenIndices(parsed: parsed, selection: textView.currentSelectedRange, in: text,
                                                suppressed: !textView.revealsSyntax)
        filterImageEmbedActiveTokens(parsed: parsed, text: text, selectionLocation: NSMaxRange(token.range))
        _ = restyleTextView(textView, paragraphCandidates: [text.paragraphRange(for: token.range)],
                            tokens: parsed.tokens, classified: parsed.classified, blocks: parsed.blocks)
        previousActiveTokenIndices = activeTokenIndices
    }
}
