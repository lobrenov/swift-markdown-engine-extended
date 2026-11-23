//
//  NativeTextView+ListGutter.swift
//  MarkdownEngine
//
//  Fork: a click in the left margin beside a gutter item (`ListStyle.gutterPrefix`) puts the caret inside its
//  collapsed prefix, where the embedder asked for it. Without this, AppKit puts it at the line's start, which is
//  after the zero-width run: the start of the item's content. Hit-tested against the line, not the collapsed
//  run, whose own text-segment rects are unreliable.
//

#if os(macOS)
import AppKit

extension NativeTextView {
    func placeCaretInListGutterIfHit(event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.clickCount == 1, mods.isEmpty,
              let tlm = textLayoutManager, let tcs = textContentStorage,
              let storage = textStorage, storage.length > 0 else { return false }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let click = CGPoint(x: viewPoint.x - textContainerOrigin.x,
                            y: viewPoint.y - textContainerOrigin.y)
        // The margin is left of the container (x < 0); fragments span the container width.
        guard let fragment = tlm.textLayoutFragment(for: CGPoint(x: max(click.x, 0), y: click.y)) else { return false }
        let fragStart = tcs.offset(from: tcs.documentRange.location, to: fragment.rangeInElement.location)
        let fragEnd = tcs.offset(from: tcs.documentRange.location, to: fragment.rangeInElement.endLocation)
        guard fragStart != NSNotFound, fragEnd != NSNotFound, fragEnd > fragStart else { return false }

        // The gutter belongs to the item's first line; a click anywhere above that line's bottom (including the
        // paragraph spacing above it) counts.
        let frame = fragment.layoutFragmentFrame
        guard let firstLine = fragment.textLineFragments.first,
              click.y <= frame.minY + firstLine.typographicBounds.maxY else { return false }

        var run: NSRange?
        var caretOffset = 0
        storage.enumerateAttribute(.listGutterCaret, in: NSRange(location: fragStart, length: fragEnd - fragStart),
                                   options: []) { value, range, stop in
            guard let offset = value as? Int else { return }
            run = range
            caretOffset = offset
            stop.pointee = true
        }
        guard let run else { return false }

        // Left of where the item's content starts is the margin.
        let contentLocal = NSMaxRange(run) - fragStart
        guard NSLocationInRange(contentLocal, firstLine.characterRange)
                || contentLocal == NSMaxRange(firstLine.characterRange) else { return false }
        let contentX = frame.minX + firstLine.typographicBounds.minX
            + firstLine.locationForCharacter(at: contentLocal).x
        guard click.x < contentX else { return false }

        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: min(run.location + caretOffset, storage.length), length: 0))
        return true
    }
}
#endif
