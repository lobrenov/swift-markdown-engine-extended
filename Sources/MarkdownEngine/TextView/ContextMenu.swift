//
//  ContextMenu.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 20.06.25.
//
//  Right-click menu: hands the system menu to the embedder. The formatting
//  actions it offers are in `MarkdownFormatting.swift`.
//

#if os(macOS)
import Cocoa
import SwiftUI

extension NativeTextViewWrapper.Coordinator {
    // The engine ships no built-in menu (API-only). It hands the default NSMenu + the
    // current selection to the embedder's onBuildContextMenu hook, which returns the menu
    // to show. The didMarkdown* actions below stay so embedders can drive them via the bus.
    public func textView(_ textView: NSTextView,
                         menu: NSMenu,
                         for event: NSEvent,
                         at charIndex: Int) -> NSMenu? {
        // Drop the system rich-text "Font" submenu (Bold/Italic/Show Colors…). Those apply
        // NSFont traits/colors that do nothing in a markdown editor (the engine owns styling),
        // so showing them would mislead. Identified by its font-panel action (locale-independent),
        // with a title fallback.
        if let fontIndex = menu.items.firstIndex(where: { item in
            if item.title == "Font" { return true }
            return item.submenu?.items.contains { $0.action == #selector(NSFontManager.orderFrontFontPanel(_:)) } ?? false
        }) {
            menu.removeItem(at: fontIndex)
        }
        guard let build = onBuildContextMenu else { return menu }
        return build(menu, textView.selectedRange())
    }
}
#endif
