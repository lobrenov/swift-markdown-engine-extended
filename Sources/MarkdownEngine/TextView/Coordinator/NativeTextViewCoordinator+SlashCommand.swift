//
//  NativeTextViewCoordinator+SlashCommand.swift
//  MarkdownEngine
//
//  Fork: a `/` typed at a line start or after whitespace opens a slash
//  command, a typed `[[` or `![[` a link or embed query, and a `#` there a tag
//  query once a tag character follows. The engine tracks
//  the query and routes the menu keys (`+Completion`); the embedder draws the
//  menu and inserts through `SlashCommandProxy`.
//

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import MarkdownEngineSyntax

/// Fork: the `/query`, `[[query`, `![[query` or `#query` being typed, delivered through
/// ``NativeTextViewWrapper/onSlashCommandChange``.
public struct SlashCommandState: Equatable, Sendable {
    /// What opened the query.
    public enum Trigger: CaseIterable, Sendable {
        /// `/`, at a line start or after whitespace.
        case slash
        /// `[[`.
        case link
        /// `![[`.
        case embed
        /// `#`, at a line start or after whitespace, reported once the query holds a character that isn't a digit
        /// (`# ` starts a heading).
        case tag

        var marker: String {
            switch self {
            case .slash: "/"
            case .link: "[["
            case .embed: "![["
            case .tag: "#"
            }
        }

        var actionName: String {
            switch self {
            case .slash: "Insert Formatting"
            case .link: "Insert Link"
            case .embed: "Insert Embed"
            case .tag: "Insert Tag"
            }
        }
    }

    public let trigger: Trigger
    /// The trigger through the caret, in display coordinates.
    public let range: NSRange
    /// The text after the trigger.
    public let query: String
    /// Only spaces or tabs precede the `/` on its line.
    public let isAtLineStart: Bool
    /// The line above is blank, or there is none.
    public let followsBlankLine: Bool
    /// The trigger's first character in screen coordinates, to anchor the menu.
    public let anchorRect: CGRect
    /// The query is in a table cell, where tables and images can't go.
    public var inTableCell = false
}

/// Fork: acts on the open slash command. Pass one to
/// ``NativeTextViewWrapper/slashCommandProxy``.
@MainActor
public final class SlashCommandProxy {
    weak var coordinator: NativeTextViewCoordinator? {
        didSet { coordinator?.slashTriggers = triggers }
    }

    public init() {}

    /// Fork: which triggers open a query; all of them by default.
    public var triggers: Set<SlashCommandState.Trigger> = Set(SlashCommandState.Trigger.allCases) {
        didSet { coordinator?.slashTriggers = triggers }
    }

    /// Fork: the editor's text view, or the table cell's that has the keyboard, for edits the embedder makes itself.
    public var textView: PlatformTextView? { coordinator?.inputTarget.textView }

    /// Replaces the query, from its trigger to the caret, with `text` (one undo step) and selects `selection`, which
    /// is relative to `text`. A link or embed query also replaces the `]]` straight after the caret.
    public func insert(_ text: String, selecting selection: NSRange) {
        coordinator?.inputTarget.insertSlashCommand(text, selecting: selection)
    }

    /// Indents the selected list lines (and their children), as Tab does.
    public func indent() {
        guard let textView = coordinator?.inputTarget.textView else { return }
        let maximumLevel = (textView as? NativeTextView)?.configuration.lists.maximumNestingLevel
            ?? MarkdownEditorConfiguration.default.lists.maximumNestingLevel
        _ = MarkdownLists.indentListLines(textView, selection: textView.currentSelectedRange, maximumLevel: maximumLevel)
    }

    /// Outdents the selected list lines (and their children), as Shift-Tab does.
    public func outdent() {
        guard let coordinator = coordinator?.inputTarget, let textView = coordinator.textView else { return }
        _ = coordinator.handleBacktab(textView)
    }

    #if os(iOS)
    /// Fork: replaces the selection with `text` as typing does, so a typed opener pairs (and a typed closer
    /// steps over one) as Autocomplete's switches say. UIKit's `insertText` bypasses the editor's input handling.
    public func type(_ text: String) {
        guard let textView = coordinator?.textView else { return }
        textView.replaceCharacters(in: textView.selectedRange, with: text)
    }
    #endif

    /// Fork: shows the source of the image embed at `location` (a drawn image hides it) and puts the caret
    /// after its `]]`. It's drawn again once the caret leaves its paragraph.
    public func revealImageEmbed(at location: Int) {
        coordinator?.revealImageEmbed(at: location)
    }

    /// Closes the menu until the next `/` is typed.
    public func dismiss() {
        coordinator?.inputTarget.dismissSlashCommand()
    }

    /// Fork: formats the selection as the editor's formatting commands do, for iOS's formatting bar and the Mac's Format menu.
    public func apply(_ format: MarkdownFormat) {
        guard let coordinator = coordinator?.inputTarget, coordinator.textView != nil else { return }
        switch format {
        case .bold: coordinator.didMarkdownBold(nil)
        case .italic: coordinator.didMarkdownItalic(nil)
        case .highlight: coordinator.didMarkdownHighlight(nil)
        case .strikethrough: coordinator.didMarkdownStrikethrough(nil)
        case .inlineCode: coordinator.didMarkdownInlineCode(nil)
        }
    }
}

/// Fork: a format ``SlashCommandProxy/apply(_:)`` toggles.
public enum MarkdownFormat: Sendable {
    case bold, italic, highlight, strikethrough, inlineCode
}

extension NativeTextViewCoordinator {

    /// Fork: the coordinator the embedder's commands act on: the table cell that has the keyboard, else this one.
    var inputTarget: NativeTextViewCoordinator {
        #if os(macOS)
        (textView as? NativeTextView)?.focusedTableCell?.coordinator ?? self
        #else
        self
        #endif
    }

    private static let slashQueryStops = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/"))

    private static let linkQueryStops = CharacterSet.newlines.union(CharacterSet(charactersIn: "[]|#^"))

    /// From `shouldChangeTextIn`, for interactive edits: a typed `/` after whitespace starts a slash query, and a
    /// typed `[` after a `[` (not a third) a link query, or an embed query after `!`, and a typed `#` after whitespace a
    /// tag query.
    func noteSlashCommandEdit(_ range: NSRange, replacement: String?, in text: NSString, codeTokens: [MarkdownToken]) {
        guard onSlashCommandChange != nil, range.length == 0 else { return }
        let start: Int, trigger: SlashCommandState.Trigger
        let followsWhitespace = range.location == 0 || Unicode.Scalar(text.character(at: range.location - 1))
            .map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
        switch replacement {
        case "/":
            // Within a link or tag query, `/` is part of the query.
            guard slashAnchor == nil || slashTrigger == .slash, followsWhitespace else { return }
            (start, trigger) = (range.location, .slash)
        case "#":
            guard followsWhitespace else { return }
            (start, trigger) = (range.location, .tag)
        case "[":
            let character = { (offset: Int) -> unichar? in
                let index = range.location - offset
                return index >= 0 ? text.character(at: index) : nil
            }
            guard character(1) == 0x5B, character(2) != 0x5B else { return }
            (start, trigger) = character(2) == 0x21 ? (range.location - 2, .embed) : (range.location - 1, .link)
        default:
            return
        }
        guard slashTriggers.contains(trigger),
              !MarkdownDetection.isInsideCodeBlock(location: range.location, codeTokens: codeTokens) else { return }
        slashAnchor = start
        slashTrigger = trigger
        isOpeningSlashCommand = true
    }

    /// From every selection change: follows the caret, or closes once it leaves the query. While the keystroke that
    /// typed the trigger is still being handled, a passing caret (an auto-pair's edit moves it past the closer before
    /// placing it) doesn't close it.
    func updateSlashCommand(in tv: PlatformTextView) {
        guard let anchor = slashAnchor else { return }
        let dismissSlashCommand = { if !self.isOpeningSlashCommand { self.dismissSlashCommand() } }
        let text = tv.string as NSString
        let selection = tv.currentSelectedRange
        let marker = slashTrigger.marker
        let markerLength = (marker as NSString).length
        guard selection.length == 0, anchor + markerLength <= text.length,
              text.substring(with: NSRange(location: anchor, length: markerLength)) == marker,
              selection.location >= anchor + markerLength else { return dismissSlashCommand() }
        let range = NSRange(location: anchor, length: selection.location - anchor)
        let query = text.substring(with: NSRange(location: anchor + markerLength, length: range.length - markerLength))
        if slashTrigger == .tag {
            guard query.count <= 100, query.allSatisfy(Self.isTagCharacter) else { return dismissSlashCommand() }
            // Typed but not yet shown: `#` alone, or digits only.
            guard query.contains(where: { !$0.isNumber && $0 != "/" }) else {
                if slashCommand != nil {
                    slashCommand = nil
                    reportSlashCommand()
                }
                return
            }
        } else {
            let (limit, stops) = slashTrigger == .slash ? (40, Self.slashQueryStops) : (100, Self.linkQueryStops)
            guard query.count <= limit, query.rangeOfCharacter(from: stops) == nil else {
                return dismissSlashCommand()
            }
        }
        let line = text.lineRange(for: NSRange(location: anchor, length: 0))
        let lead = text.substring(with: NSRange(location: line.location, length: anchor - line.location))
        let followsBlankLine: Bool = {
            guard line.location > 0 else { return true }
            let above = text.lineRange(for: NSRange(location: line.location - 1, length: 0))
            return text.substring(with: above).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }()
        slashCommand = SlashCommandQuery(trigger: slashTrigger, range: range, query: query,
                                         isAtLineStart: lead.allSatisfy { $0 == " " || $0 == "\t" },
                                         followsBlankLine: followsBlankLine)
        reportSlashCommand()
    }

    private static func isTagCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "-" || c == "/"
    }

    func dismissSlashCommand() {
        slashAnchor = nil
        guard slashCommand != nil else { return }
        slashCommand = nil
        reportSlashCommand()
    }

    func insertSlashCommand(_ insertion: String, selecting selection: NSRange) {
        guard let tv = textView, let command = slashCommand else { return }
        dismissSlashCommand()
        let text = tv.string as NSString
        var range = command.range
        guard NSMaxRange(range) <= text.length else { return }
        if command.trigger == .link || command.trigger == .embed, NSMaxRange(range) + 2 <= text.length,
           text.substring(with: NSRange(location: NSMaxRange(range), length: 2)) == "]]" {
            range.length += 2
        }
        tv.breakUndoCoalescing()
        isProgrammaticEdit = true
        defer { isProgrammaticEdit = false }
        guard tv.shouldChangeText(in: range, replacementString: insertion) else { return }
        tv.optionalTextStorage?.replaceCharacters(in: range, with: insertion)
        tv.didChangeText()
        tv.undoManager?.setActionName(command.trigger.actionName)
        tv.breakUndoCoalescing()
        tv.setSelectedRange(NSRange(location: range.location + selection.location, length: selection.length))
        if command.trigger == .slash { openLinkQuery(endingAt: range.location + selection.location, in: tv) }
    }

    /// A slash command that leaves the caret straight after a `[[` or `![[` opens that link or embed query.
    private func openLinkQuery(endingAt caret: Int, in tv: PlatformTextView) {
        let text = tv.string as NSString
        guard tv.currentSelectedRange == NSRange(location: caret, length: 0), caret >= 2,
              text.substring(with: NSRange(location: caret - 2, length: 2)) == "[[",
              caret < 3 || text.character(at: caret - 3) != 0x5B else { return }
        let isEmbed = caret >= 3 && text.character(at: caret - 3) == 0x21
        let trigger: SlashCommandState.Trigger = isEmbed ? .embed : .link
        guard slashTriggers.contains(trigger) else { return }
        slashAnchor = caret - (isEmbed ? 3 : 2)
        slashTrigger = trigger
        updateSlashCommand(in: tv)
    }

    /// Deferred so layout has caught up (the anchor rect is current) and SwiftUI isn't mid-update.
    /// Reads the latest query when it runs, so a burst of keystrokes reports once.
    private func reportSlashCommand() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var state: SlashCommandState?
            if let command = slashCommand, let tv = textView {
                let anchor = tv.anchorRect(forCharacterRange: NSRange(location: command.range.location, length: 1))
                state = SlashCommandState(trigger: command.trigger, range: command.range, query: command.query,
                                          isAtLineStart: command.isAtLineStart,
                                          followsBlankLine: command.followsBlankLine, anchorRect: anchor)
                #if os(macOS)
                state?.inTableCell = (tv as? NativeTextView)?.hidesSyntaxUnlessFocused == true
                #endif
            }
            guard state != reportedSlashCommand else { return }
            reportedSlashCommand = state
            onSlashCommandChange?(state)
        }
    }
}

/// Fork: the open query (see `NativeTextViewCoordinator+SlashCommand`).
struct SlashCommandQuery {
    let trigger: SlashCommandState.Trigger
    let range: NSRange
    let query: String
    let isAtLineStart: Bool
    let followsBlankLine: Bool
}
