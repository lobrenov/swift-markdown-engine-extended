//
//  MenuRequests.swift
//  MarkdownEngine
//
//  Fork: the menus the embedder draws for a task box or a callout title,
//  opened by a right-click on macOS and a press and hold on iOS.
//

import CoreGraphics

/// Fork: a right-click (or press and hold) on a task box, delivered through
/// ``NativeTextViewWrapper/onTaskMarkerMenu``.
public struct TaskMarkerMenuRequest {
    /// The box's current marker.
    public let marker: Character
    /// The box in screen coordinates, to anchor the menu.
    public let anchorRect: CGRect
    /// Replaces the marker as one undoable edit. Does nothing once the box's text has changed.
    public let setMarker: @MainActor (Character) -> Void
}

/// Fork: a right-click (or press and hold) on a callout's title line, delivered through
/// ``NativeTextViewWrapper/onCalloutMenu``.
public struct CalloutMenuRequest {
    /// The type as written, between `[!` and `]`.
    public let type: String
    /// `+`, `-` or nil.
    public let fold: Character?
    /// The icon in screen coordinates, to anchor the menu.
    public let anchorRect: CGRect
    /// Replaces the type as one undoable edit. Does nothing once the title line has changed.
    public let setType: @MainActor (String) -> Void
    /// Sets, changes or removes the fold sign as one undoable edit. Does nothing once the title line has changed.
    public let setFold: @MainActor (Character?) -> Void
    /// Call when the menu closes: the callout drops its ring.
    public let close: @MainActor () -> Void
}

/// Fork: one row of a right-click menu.
public struct RightClickMenuItem {
    public let title: String
    /// An SF Symbol name.
    public let symbolName: String?
    /// A key hint shown on the right, such as `⌘⌫`.
    public let shortcut: String?
    /// Drawn with a tick: the current choice.
    public let isChecked: Bool
    public let isDestructive: Bool
    public let action: @MainActor () -> Void

    init(_ title: String, symbolName: String? = nil, shortcut: String? = nil, isChecked: Bool = false,
         isDestructive: Bool = false, action: @escaping @MainActor () -> Void) {
        self.title = title
        self.symbolName = symbolName
        self.shortcut = shortcut
        self.isChecked = isChecked
        self.isDestructive = isDestructive
        self.action = action
    }
}

/// Fork: a right-click on something that offers a menu (a table's row or column grip), delivered through
/// ``NativeTextViewWrapper/onRightClickMenu``. The engine rings what was clicked until `close`.
public struct RightClickMenuRequest {
    /// The menu's items in groups, with a divider between groups.
    public let sections: [[RightClickMenuItem]]
    /// What was clicked, in screen coordinates, to anchor the menu.
    public let anchorRect: CGRect
    /// Call when the menu closes: the ring goes.
    public let close: @MainActor () -> Void
}

/// Fork: a drawn image's `![[ ]]`, for the embedder's image actions: ``NativeTextViewWrapper/onImageEmbed`` on
/// macOS, ``NativeTextViewWrapper/imageEmbedMenu`` on iOS.
public struct ImageEmbedRequest {
    public enum Action: Sendable {
        /// A right-click (or press and hold) on the image: the embedder shows its menu.
        case menu
        /// ⌘C, ⌘X or ⌘⌫ while the image is selected.
        case copy, cut, delete
    }

    public let action: Action
    /// The text between `![[` and `]]`.
    public let name: String
    /// Where a right-click landed, else the image; in screen coordinates on macOS and window coordinates on iOS.
    public let anchorRect: CGRect
    /// Removes the `![[ ]]` as one undoable edit with this action name. Does nothing once its text has changed.
    public let remove: @MainActor (_ actionName: String) -> Void
    /// Shows the `![[ ]]` with the caret after it, until the caret leaves its line.
    public let revealSource: @MainActor () -> Void
    /// Call when the menu closes: the image drops its ring unless it's selected.
    public let close: @MainActor () -> Void
}
