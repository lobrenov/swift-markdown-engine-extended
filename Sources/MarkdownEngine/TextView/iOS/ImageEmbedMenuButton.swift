//
//  ImageEmbedMenuButton.swift
//  MarkdownEngine
//
//  Fork: a press and hold on a drawn image shows the embedder's menu
//  (`imageEmbedMenu`) at the press, from an invisible menu button there.
//

#if os(iOS)
import UIKit

extension NativeTextView {
    /// The embedder's menu for the image embed at `range`; nil when there's none.
    func imageEmbedMenu(for range: NSRange) -> UIMenu? {
        guard let imageEmbedMenu, let rect = imageEmbedRect(for: range) else { return nil }
        return imageEmbedMenu(imageEmbedRequest(.menu, range: range, anchorViewRect: rect))
    }

    func showImageEmbedMenu(_ menu: UIMenu, at point: CGPoint) {
        let button = imageMenuButton ?? {
            let button = UIButton(type: .custom)
            button.showsMenuAsPrimaryAction = true
            button.isAccessibilityElement = false
            addSubview(button)
            imageMenuButton = button
            return button
        }()
        button.frame = CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
        button.menu = menu
        button.performPrimaryAction()
    }
}
#endif
