//
//  NativeTextView+ImageSelection.swift
//  MarkdownEngine
//
//  Fork: with `imageEmbed.selectionRing` set, a click on a drawn image
//  selects its `![[ ]]`, and a right-click also hands it to `onImageEmbed` for
//  the embedder's menu. While an image is selected, ⌘C, ⌘X and ⌘⌫ go to
//  `onImageEmbed` too; ⌫ deletes the `![[ ]]` as any selection.
//

#if os(macOS)
import AppKit

extension NativeTextView {

    /// Selects the image under a plain click. Returns true when it did.
    func selectImageEmbedIfHit(event: NSEvent) -> Bool {
        guard configuration.imageEmbed.selectionRing != nil,
              event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
              let hit = imageEmbedHit(atViewPoint: convert(event.locationInWindow, from: nil)) else { return false }
        window?.makeFirstResponder(self)
        setSelectedRange(hit.range)
        return true
    }

    /// Selects the image under a right-click and hands it to `onImageEmbed`, ringing it until the menu closes.
    /// Returns true when it did.
    func showImageEmbedMenuIfHit(event: NSEvent) -> Bool {
        guard let onImageEmbed, configuration.imageEmbed.selectionRing != nil else { return false }
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = imageEmbedHit(atViewPoint: point) else { return false }
        window?.makeFirstResponder(self)
        setSelectedRange(hit.range)
        setImageEmbedMenuTarget(hit.range)
        onImageEmbed(imageEmbedRequest(.menu, range: hit.range, anchorViewRect: CGRect(origin: point, size: .zero)))
        return true
    }

    /// Hands the selected image to `onImageEmbed` for `action`. Returns true when an image was selected.
    func sendSelectedImageEmbed(_ action: ImageEmbedRequest.Action) -> Bool {
        guard let onImageEmbed, let range = selectedImageEmbed, range == selectedRange(),
              let rect = imageEmbedRect(for: range) else { return false }
        onImageEmbed(imageEmbedRequest(action, range: range, anchorViewRect: rect))
        return true
    }

    override func cut(_ sender: Any?) {
        if sendSelectedImageEmbed(.cut) { return }
        super.cut(sender)
    }

    override func deleteToBeginningOfLine(_ sender: Any?) {
        if sendSelectedImageEmbed(.delete) { return }
        super.deleteToBeginningOfLine(sender)
    }
}
#endif
