//
//  NativeTextView+Callout.swift
//  MarkdownEngine
//
//  Fork: a click on a foldable callout's title row (its icon, chevron
//  or the space past its title) folds or opens it on screen; the file keeps
//  its `+` or `-`. A right-click on a title line goes to `onCalloutMenu`,
//  which can change the type and the fold sign.
//

#if os(macOS)
import AppKit

extension NativeTextView {

    /// The callout title line under `event`, if any.
    func calloutTitleHit(for event: NSEvent) -> CalloutTitleHit? {
        calloutTitleHit(atViewPoint: convert(event.locationInWindow, from: nil))
    }

    /// Folds or opens the callout when `event` lands on its title row outside the title text. Returns true when
    /// it did.
    func toggleCalloutFoldIfHit(event: NSEvent) -> Bool {
        guard event.clickCount == 1, event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty,
              let hit = calloutTitleHit(for: event) else { return false }
        return toggleCalloutFold(hit)
    }

}
#endif
