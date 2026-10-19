//
//  LeadingCalloutPadding.swift
//  MarkdownEngine
//
//  Fork: TextKit gives the document's first paragraph no spacing before it, so a callout that opens the
//  document takes its top padding from the text inset instead.
//

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

extension NativeTextView {
    /// The top padding of a callout that opens on the document's first line, or 0.
    var leadingCalloutPadding: CGFloat {
        guard let storage = optionalTextStorage, storage.length > 0,
              let line = storage.attribute(.calloutLine, at: 0, effectiveRange: nil) as? CalloutLine,
              let panel = line.panels.first, panel.opens else { return 0 }
        return panel.topPadding
    }

    /// Sets the text inset for `leadingCalloutPadding`. On the Mac the inset is vertical, so it pads below the
    /// text too.
    func fitLeadingCalloutPadding() {
        #if os(macOS)
        let height = configuration.textInsets.vertical + leadingCalloutPadding
        if abs(textContainerInset.height - height) > 0.5 { textContainerInset.height = height }
        #else
        applyInsets()
        #endif
    }
}
