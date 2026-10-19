//
//  ImageEmbedHits.swift
//  MarkdownEngine
//
//  Fork: the drawn image embed under a point, the images that draw a
//  ring (the selected one and the one whose menu is open), and the request the
//  embedder's image actions get. The Mac's source button
//  (`NativeTextView+ImageSourceButton.swift`), clicks and keys
//  (`NativeTextView+ImageSelection.swift`) and the iOS menu
//  (`iOS/ImageEmbedMenuButton.swift`) use them.
//

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

extension NativeTextView {
    /// The drawn image under a point in the text view's coordinates: its `![[ ]]` range and the image's rect in
    /// view coordinates.
    func imageEmbedHit(atViewPoint viewPoint: CGPoint) -> (range: NSRange, rect: CGRect)? {
        guard let coordinator = delegate as? NativeTextViewCoordinator, let storage = optionalTextStorage,
              storage.length > 0 else { return nil }
        for token in coordinator.parsedDocument(for: string).imageEmbedTokens
            where NSMaxRange(token.range) <= storage.length && token.range.location != coordinator.revealedImageEmbed {
            if let rect = imageEmbedRect(for: token.range), rect.contains(viewPoint) { return (token.range, rect) }
        }
        return nil
    }

    /// The drawn image of the `![[ ]]` at `range`, in view coordinates; nil when it isn't drawn.
    func imageEmbedRect(for range: NSRange) -> CGRect? {
        guard let textContainer = optionalTextContainer, let bridge = layoutBridge, let storage = optionalTextStorage,
              NSMaxRange(range) <= storage.length else { return nil }
        var rect: CGRect?
        storage.enumerateAttribute(.latexImage, in: range) { value, attrRange, stop in
            guard value != nil, let bounds = (storage.attribute(.latexBounds, at: attrRange.location, effectiveRange: nil)
                as? NSValue)?.rectValue else { return }
            let anchor = bridge.boundingRect(forCharacterRange: NSRange(location: attrRange.location, length: 1), in: textContainer)
            rect = CGRect(x: anchor.minX + textContainerOrigin.x, y: anchor.minY + textContainerOrigin.y,
                          width: bounds.width, height: bounds.height)
            stop.pointee = true
        }
        return rect
    }

    /// Whether the image drawn at `location` has a ring: it's selected, or its menu is open.
    func ringsImage(at location: Int) -> Bool {
        [selectedImageEmbed, imageEmbedMenuTarget].contains { $0.map { NSLocationInRange(location, $0) } == true }
    }

    func setSelectedImageEmbed(_ range: NSRange?) {
        guard range != selectedImageEmbed else { return }
        let old = selectedImageEmbed
        selectedImageEmbed = range
        redrawImageRings(old, range)
    }

    func setImageEmbedMenuTarget(_ range: NSRange?) {
        guard range != imageEmbedMenuTarget else { return }
        let old = imageEmbedMenuTarget
        imageEmbedMenuTarget = range
        redrawImageRings(old, range)
    }

    private func redrawImageRings(_ ranges: NSRange?...) {
        let length = optionalTextStorage?.length ?? 0
        for range in ranges.compactMap({ $0 }) where NSMaxRange(range) <= length {
            layoutBridge?.invalidateDisplay(forCharacterRange: range)
        }
    }

    /// The request for the image embed at `range`, anchored at `anchorViewRect` (view coordinates).
    func imageEmbedRequest(_ action: ImageEmbedRequest.Action, range: NSRange, anchorViewRect: CGRect) -> ImageEmbedRequest {
        let source = (string as NSString).substring(with: range)
        let name = String(source.dropFirst(3).dropLast(2))
        return ImageEmbedRequest(
            action: action, name: name, anchorRect: menuAnchorRect(forViewRect: anchorViewRect),
            remove: { [weak self] actionName in
                guard let self, let storage = self.optionalTextStorage, NSMaxRange(range) <= storage.length,
                      (storage.string as NSString).substring(with: range) == source else { return }
                self.breakUndoCoalescing()
                MarkdownLists.performEdit(self, replace: range, with: "")
                self.undoManager?.setActionName(actionName)
                self.breakUndoCoalescing()
                self.setSelectedRange(NSRange(location: range.location, length: 0))
            },
            revealSource: { [weak self] in
                guard let self, let storage = self.optionalTextStorage, NSMaxRange(range) <= storage.length,
                      (storage.string as NSString).substring(with: range) == source else { return }
                #if os(iOS)
                if !self.isFirstResponder { self.becomeFirstResponder() }
                #endif
                (self.delegate as? NativeTextViewCoordinator)?.revealImageEmbed(at: range.location)
            },
            close: { [weak self] in
                if self?.imageEmbedMenuTarget == range { self?.setImageEmbedMenuTarget(nil) }
            })
    }
}

extension NativeTextViewCoordinator {
    /// From every selection change: with `imageEmbed.selectionRing` set, a selection of exactly a drawn image's
    /// `![[ ]]` selects the image.
    func updateSelectedImageEmbed(in textView: PlatformTextView) {
        guard configuration.imageEmbed.selectionRing != nil, let view = textView as? NativeTextView else { return }
        let selection = textView.currentSelectedRange
        let token = selection.length > 0 ? collapsedImageEmbed(touching: selection, in: textView) : nil
        view.setSelectedImageEmbed(token?.range == selection ? selection : nil)
    }
}
