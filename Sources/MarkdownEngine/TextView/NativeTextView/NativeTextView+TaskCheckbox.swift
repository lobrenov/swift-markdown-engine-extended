//
//  NativeTextView+TaskCheckbox.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Hit-test for `[ ]` / `[x]` checkbox glyphs and toggle the underlying text
//  + `.taskCheckbox` attribute, then nudge the coordinator to restyle the
//  enclosing paragraph.
//
//  Fork: any `TaskMarker` character is a checkbox. A click follows
//  `TaskCheckboxStyle.clickTransitions`; a right-click on the box offers every
//  marker in `TaskCheckboxStyle.menuItems`, or goes to `onTaskMarkerMenu` for
//  the embedder to draw its own menu.
//

#if os(macOS)
import AppKit

extension NativeTextView {

    func taskCheckboxHit(for event: NSEvent) -> (range: NSRange, marker: Character, rect: CGRect)? {
        taskCheckboxHit(atViewPoint: convert(event.locationInWindow, from: nil))
    }

    /// Applies the click transition for the box under `event`. Returns true when
    /// the click landed on a box (consumed, even if its marker ignores clicks).
    func toggleTaskCheckboxIfHit(event: NSEvent) -> Bool? {
        guard let hit = taskCheckboxHit(for: event) else { return nil }
        toggleTaskCheckbox(hit)
        return true
    }

    /// The marker menu for a right-click on `hit`, or nil after handing the click to `onTaskMarkerMenu`.
    func taskMarkerMenu(for hit: (range: NSRange, marker: Character, rect: CGRect)) -> NSMenu? {
        if let onTaskMarkerMenu {
            onTaskMarkerMenu(taskMarkerMenuRequest(for: hit))
            return nil
        }
        let style = configuration.taskCheckbox
        let menu = NSMenu()
        for entry in style.menuItems {
            let target = TaskMarkerMenuTarget(textView: self, boxRange: hit.range, marker: entry.marker)
            let item = NSMenuItem(title: entry.title, action: #selector(TaskMarkerMenuTarget.apply), keyEquivalent: "")
            item.target = target
            item.representedObject = target   // NSMenuItem.target is weak
            if let draw = style.draw {
                let tint = style.tints[entry.marker]
                    ?? (entry.marker == " " ? configuration.theme.mutedText : configuration.theme.bodyText)
                item.image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { rect in
                    draw(entry.marker, rect, tint)
                    return true
                }
            } else {
                item.image = style.symbolNames[entry.marker].flatMap {
                    NSImage(systemSymbolName: $0, accessibilityDescription: entry.title)
                }
            }
            item.state = entry.marker == hit.marker ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

}

private final class TaskMarkerMenuTarget: NSObject {
    weak var textView: NativeTextView?
    let boxRange: NSRange
    let marker: Character

    init(textView: NativeTextView, boxRange: NSRange, marker: Character) {
        self.textView = textView
        self.boxRange = boxRange
        self.marker = marker
    }

    @objc func apply() {
        textView?.setTaskMarker(marker, boxRange: boxRange)
    }
}
#endif
