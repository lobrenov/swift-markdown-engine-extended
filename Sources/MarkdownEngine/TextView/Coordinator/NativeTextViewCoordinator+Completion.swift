//
//  NativeTextViewCoordinator+Completion.swift
//  MarkdownEngine
//
//  Fork: one owner for the menu keys. A slash, link, embed or tag query
//  (`+SlashCommand`), upstream's wiki-link and image-embed preview, and
//  upstream's directive picker (`+Directives`) each report their own state;
//  the keys go to whichever owns the caret, in that order, through
//  `onInlinePreviewKey`.
//

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Fork: the picker that owns ↑/↓/↵/esc while it's open.
enum CompletionOwner: Equatable {
    /// A slash, link, embed or tag query.
    case query
    /// Upstream's `[[…]]` / `![[…]]` preview.
    case inlinePreview
    /// Upstream's directive picker.
    case directive
}

extension NativeTextViewCoordinator {

    /// The open picker, by precedence: a query, then the inline preview, then the directive picker.
    var completionOwner: CompletionOwner? {
        if slashCommand != nil { return .query }
        if isWikiLinkActive || isImageEmbedActive { return .inlinePreview }
        if isDirectiveCompletionActive { return .directive }
        return nil
    }

    /// Sends `key` to the open picker. esc closes a query in the engine; every other key goes to
    /// `onInlinePreviewKey`. `true` when the key was consumed.
    func routeCompletionKey(_ key: InlinePreviewKey) -> Bool {
        guard let owner = completionOwner else { return false }
        if owner == .query, key == .cancel {
            dismissSlashCommand()
            return true
        }
        return onInlinePreviewKey?(key) ?? false
    }

    #if os(macOS)
    /// From `doCommandBy`: ↑, ↓, ↵ and esc for any picker; ⇥ confirms a query.
    func routeCompletionCommand(_ commandSelector: Selector) -> Bool {
        guard let owner = completionOwner else { return false }
        let key: InlinePreviewKey
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)): key = .moveUp
        case #selector(NSResponder.moveDown(_:)): key = .moveDown
        case #selector(NSResponder.insertNewline(_:)): key = .confirm   // ⌘↵ → `performKeyEquivalent`
        case #selector(NSResponder.insertTab(_:)) where owner == .query: key = .confirm
        case #selector(NSResponder.cancelOperation(_:)): key = .cancel
        default: return false
        }
        return routeCompletionKey(key)
    }
    #endif
}
