//
//  TextMenuTests.swift
//  MarkdownEngineTests
//
//  Fork: a right-click on text goes to `onTextMenu` (FORK.md #35).
//

#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine
@testable import MarkdownEngineSyntax

@MainActor
@Suite("Fork — text menu")
struct TextMenuTests {

    private static let calloutStyle = CalloutStyle(
        tint: { _ in .systemBlue }, drawIcon: { _, _, _ in }, titleColor: .labelColor, bodyColor: .textColor,
        foldColor: .gray, targetColor: .systemRed, fillOpacity: 0.09, ringOpacity: 0.24)

    private struct Rig {
        let tv: NativeTextView
        let window: NSWindow
        let coordinator: NativeTextViewCoordinator
        var requests: [TextMenuRequest] = []
    }

    /// An editor showing `text` (storage form), the caret at 0, with formatting extensions and callouts on.
    private func rig(_ text: String) throws -> Rig {
        _ = NSApplication.shared
        var configuration = MarkdownEditorConfiguration.default
        configuration.extensions = [HighlightExtension(), StrikethroughExtension()]
        configuration.callouts = Self.calloutStyle
        let coordinator = NativeTextViewCoordinator(
            text: .constant(text), fontName: "SF Pro", fontSize: 14,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil)
        coordinator.configuration = configuration
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.configuration = configuration
        tv.isEditable = true
        tv.allowsUndo = true
        tv.delegate = coordinator
        let scrollView = NSScrollView(frame: tv.frame)
        scrollView.documentView = tv
        let window = NSWindow(contentRect: tv.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scrollView
        let bridge = LayoutBridge(try #require(tv.textLayoutManager))
        coordinator.layoutBridge = bridge
        tv.layoutBridge = bridge
        coordinator.textView = tv
        coordinator.rebuildTextStorageAndStyle(tv, from: text)
        coordinator.lastSyncedText = text
        coordinator.lastComputedStorage = text
        coordinator.previousDisplayLength = (text as NSString).length
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        return Rig(tv: tv, window: window, coordinator: coordinator)
    }

    /// A right-click event on the middle of the first `needle` in the editor's text.
    private func rightClick(_ needle: String, in rig: Rig) throws -> NSEvent {
        let range = (rig.tv.string as NSString).range(of: needle)
        try #require(range.location != NSNotFound)
        let rect = try #require(rig.tv.layoutBridge).boundingRect(forCharacterRange: range, in: try #require(rig.tv.textContainer))
        let point = CGPoint(x: rect.midX + rig.tv.textContainerOrigin.x, y: rect.midY + rig.tv.textContainerOrigin.y)
        return try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: rig.tv.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: rig.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// Right-clicks `needle` and returns the request `onTextMenu` got.
    private func request(on needle: String, in rig: Rig, selecting selection: NSRange? = nil) throws -> TextMenuRequest {
        var received: [TextMenuRequest] = []
        rig.tv.onTextMenu = { received.append($0) }
        if let selection { rig.tv.setSelectedRange(selection) }
        #expect(rig.tv.menu(for: try rightClick(needle, in: rig)) == nil)
        return try #require(received.first)
    }

    // MARK: Request contents

    @Test func aCaretRequestHoldsTheCaretAndNoText() throws {
        let rig = try rig("Hello world\n")
        let request = try request(on: "world", in: rig)
        #expect(request.selection.length == 0)
        #expect((8...11).contains(request.selection.location))
        #expect(rig.tv.selectedRange() == request.selection)
        #expect(request.selectedText == "" && !request.hasSelection)
        #expect(request.link == nil && request.activeFormats.isEmpty && request.blockKind == .body)
        #expect(request.anchorRect != .zero)
    }

    @Test func aRightClickInsideTheSelectionKeepsIt() throws {
        let rig = try rig("Hello world\n")
        let request = try request(on: "ello", in: rig, selecting: NSRange(location: 0, length: 5))
        #expect(request.selection == NSRange(location: 0, length: 5))
        #expect(request.selectedText == "Hello" && request.hasSelection)
        #expect(rig.tv.selectedRange() == NSRange(location: 0, length: 5))
    }

    @Test func aRightClickOutsideTheSelectionMovesTheCaret() throws {
        let rig = try rig("Hello world\n")
        let request = try request(on: "world", in: rig, selecting: NSRange(location: 0, length: 5))
        #expect(request.selection.length == 0 && request.selection.location >= 6)
    }

    @Test func aWikiLinkUnderThePointerIsReadAsWritten() throws {
        let rig = try rig("See [[Note#Part|alias]] now\n")
        let link = try #require(try request(on: "Note", in: rig).link)
        #expect(link.kind == .wiki)
        #expect(link.target == "Note" && link.heading == "Part" && link.block == nil && link.alias == "alias")
        #expect(link.source == "[[Note#Part|alias]]")
        #expect((rig.tv.string as NSString).substring(with: link.range).hasPrefix("[[Note"))
    }

    @Test func aPlainWikiLinkHasOnlyATarget() throws {
        let rig = try rig("See [[Note]] now\n")
        let link = try #require(try request(on: "Note", in: rig).link)
        #expect(link.target == "Note" && link.heading == nil && link.alias == nil && link.source == "[[Note]]")
        #expect(link.range == NSRange(location: 4, length: 8))
    }

    @Test func aMarkdownLinkCarriesItsURL() throws {
        let rig = try rig("Go [site](https://a.example/c) ok\n")
        let link = try #require(try request(on: "site", in: rig).link)
        #expect(link.kind == .markdown && link.target == "https://a.example/c" && link.alias == "site")
        #expect(link.source == "[site](https://a.example/c)" && link.range == NSRange(location: 3, length: 27))
    }

    @Test func textAwayFromALinkHasNone() throws {
        let rig = try rig("See [[Note]] now\n")
        #expect(try request(on: "now", in: rig).link == nil)
    }

    @Test func formatsComeFromTheSelection() throws {
        let rig = try rig("a **bold** *it* ~~s~~ ==h== `c` plain\n")
        let cases: [(String, Set<MarkdownFormat>)] = [
            ("bold", [.bold]), ("it", [.italic]), ("s", [.strikethrough]), ("h", [.highlight]), ("c", [.inlineCode]),
            ("plain", []),
        ]
        for (word, formats) in cases {
            let range = (rig.tv.string as NSString).range(of: word, options: [], range: NSRange(location: 2, length: (rig.tv.string as NSString).length - 2))
            let request = try request(on: word, in: rig, selecting: range)
            #expect(request.activeFormats == formats, "\(word)")
        }
    }

    @Test func formatsComeFromTheWordUnderTheCaret() throws {
        let rig = try rig("a **bold** plain\n")
        #expect(try request(on: "bold", in: rig).activeFormats == [.bold])
        #expect(try request(on: "plain", in: rig).activeFormats.isEmpty)
    }

    @Test func nestedFormatsAllShow() throws {
        let rig = try rig("a ***both*** b\n")
        let range = (rig.tv.string as NSString).range(of: "both")
        #expect(try request(on: "both", in: rig, selecting: range).activeFormats == [.bold, .italic])
    }

    @Test func theLineKindIsRead() throws {
        let rig = try rig("# One\n### Three\n###### Six\n- bullet\n* star\n1. numbered\n2) paren\n- [ ] task\n- [x] done\n> quote\nbody\n---\n####### seven\n")
        let kinds: [(String, TextMenuBlockKind)] = [
            ("One", .heading(1)), ("Three", .heading(3)), ("Six", .heading(6)), ("bullet", .bullet), ("star", .bullet),
            ("numbered", .numbered), ("paren", .numbered), ("task", .task), ("done", .task), ("quote", .quote),
            ("body", .body), ("---", .body), ("seven", .body),
        ]
        for (word, kind) in kinds {
            #expect(try request(on: word, in: rig).blockKind == kind, "\(word)")
        }
    }

    @Test func theKindComesFromTheSelectionsFirstLine() throws {
        let rig = try rig("# One\nbody\n")
        let request = try request(on: "body", in: rig, selecting: NSRange(location: 0, length: 9))
        #expect(request.blockKind == .heading(1))
    }

    @Test func followsBlankLineReadsTheLineAbove() throws {
        let rig = try rig("a\n\nb\nc\n")
        #expect(try request(on: "b", in: rig).followsBlankLine)
        #expect(try !request(on: "c", in: rig).followsBlankLine)
        #expect(try request(on: "a", in: rig).followsBlankLine)
    }

    // MARK: Actions

    @Test func toggleFormatWrapsTheSelectionAndUnwrapsIt() throws {
        let rig = try rig("Hello world\n")
        let request = try request(on: "Hello", in: rig, selecting: NSRange(location: 0, length: 5))
        request.toggleFormat(.bold)
        #expect(rig.tv.string == "**Hello** world\n")
        request.toggleFormat(.bold)
        #expect(rig.tv.string == "Hello world\n")
    }

    @Test(arguments: [(MarkdownFormat.bold, "**"), (.italic, "*"), (.strikethrough, "~~"), (.highlight, "=="), (.inlineCode, "`")])
    func toggleFormatWithACaretActsOnTheWord(format: MarkdownFormat, marker: String) throws {
        let rig = try rig("Hello world\n")
        let request = try request(on: "world", in: rig)
        request.toggleFormat(format)
        #expect(rig.tv.string == "Hello \(marker)world\(marker)\n")
        let again = try self.request(on: "world", in: rig)
        #expect(again.activeFormats == [format])
        again.toggleFormat(format)
        #expect(rig.tv.string == "Hello world\n")
    }

    @Test func setBlockKindReplacesAndTogglesOff() throws {
        let rig = try rig("Hello\n")
        let request = try request(on: "Hello", in: rig)
        let cases: [(TextMenuBlockKind, String)] = [
            (.heading(2), "## Hello\n"), (.bullet, "- Hello\n"), (.numbered, "1. Hello\n"), (.task, "- [ ] Hello\n"),
            (.quote, "> Hello\n"), (.heading(1), "# Hello\n"), (.body, "Hello\n"),
        ]
        for (kind, text) in cases {
            request.setBlockKind(kind)
            #expect(rig.tv.string == text, "\(kind)")
        }
        request.setBlockKind(.heading(3))
        #expect(rig.tv.string == "### Hello\n")
        request.setBlockKind(.heading(3))
        #expect(rig.tv.string == "Hello\n")
    }

    @Test func setBlockKindKeepsIndentAndOtherLinesAndTheCaretInTheText() throws {
        let rig = try rig("a\n  - [x] done *it*\nb\n")
        let request = try request(on: "done", in: rig)
        let before = (rig.tv.string as NSString).range(of: "done").location
        request.setBlockKind(.numbered)
        #expect(rig.tv.string == "a\n  1. done *it*\nb\n")
        let caret = rig.tv.selectedRange().location
        #expect(caret >= (rig.tv.string as NSString).range(of: "1. ").upperBound)
        #expect(caret <= before + 10)
    }

    @Test func setBlockKindIsOneUndoStep() throws {
        let rig = try rig("Hello\n")
        try request(on: "Hello", in: rig).setBlockKind(.heading(1))
        #expect(rig.tv.string == "# Hello\n")
        rig.tv.undoManager?.undo()
        #expect(rig.tv.string == "Hello\n")
    }

    @Test func insertReplacesTheSelectionAndSelectsThePlaceholder() throws {
        let rig = try rig("Hello world\n")
        let request = try request(on: "Hello", in: rig, selecting: NSRange(location: 0, length: 5))
        request.insert("[x]()", selecting: NSRange(location: 1, length: 1), asBlock: false)
        #expect(rig.tv.string == "[x]() world\n")
        #expect(rig.tv.selectedRange() == NSRange(location: 1, length: 1))
    }

    @Test func insertAtACaretKeepsTheText() throws {
        let rig = try rig("Hello world\n")
        let request = try request(on: "world", in: rig)
        let caret = rig.tv.selectedRange().location
        request.insert("[[]]", selecting: NSRange(location: 2, length: 0), asBlock: false)
        #expect((rig.tv.string as NSString).contains("[[]]"))
        #expect(rig.tv.selectedRange() == NSRange(location: caret + 2, length: 0))
    }

    @Test func insertingAWikilinkOpensTheLinkQuery() async throws {
        let rig = try rig("Hello world\n")
        var states: [SlashCommandState?] = []
        rig.coordinator.onSlashCommandChange = { states.append($0) }
        let request = try request(on: "Hello", in: rig, selecting: NSRange(location: 0, length: 0))
        request.insert("[[]]", selecting: NSRange(location: 2, length: 0), asBlock: false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(states.last??.trigger == .link)
    }

    @Test func aBlockInsertMidLineStartsALine() throws {
        let rig = try rig("Hello world\n")
        let request = try request(on: "world", in: rig)
        let caret = rig.tv.selectedRange().location
        #expect(caret > 0)
        request.insert("---\n", selecting: NSRange(location: 4, length: 0), asBlock: true)
        let text = rig.tv.string as NSString
        #expect(text.range(of: "\n---\n").location != NSNotFound)
        #expect(rig.tv.selectedRange().location == caret + 5)
    }

    @Test func aBlockInsertOnAnEmptyLineAddsNoBreak() throws {
        let rig = try rig("a\n\nb\n")
        rig.tv.setSelectedRange(NSRange(location: 2, length: 0))
        var received: [TextMenuRequest] = []
        rig.tv.onTextMenu = { received.append($0) }
        _ = rig.tv.menu(for: try rightClick("b", in: rig))
        rig.tv.setSelectedRange(NSRange(location: 2, length: 0))
        try #require(received.first).insert("```\n§\n```", selecting: NSRange(location: 4, length: 0), asBlock: true)
        #expect(rig.tv.string == "a\n```\n§\n```\nb\n")
    }

    @Test func replaceSelectionSwapsTheRequestedTextOnce() throws {
        let rig = try rig("Hello world\n")
        let request = try request(on: "Hello", in: rig, selecting: NSRange(location: 0, length: 5))
        request.replaceSelection("[[Hello]]")
        #expect(rig.tv.string == "[[Hello]] world\n")
        #expect(rig.tv.selectedRange() == NSRange(location: 9, length: 0))
        request.replaceSelection("again")
        #expect(rig.tv.string == "[[Hello]] world\n", "the text under the request's range has changed")
    }

    @Test func clipboardActions() throws {
        let rig = try rig("Hello world\n")
        let pasteboard = NSPasteboard.general
        let request = try request(on: "Hello", in: rig, selecting: NSRange(location: 0, length: 5))
        request.copy()
        #expect(pasteboard.string(forType: .string) == "Hello")
        request.cut()
        #expect(rig.tv.string == " world\n")
        pasteboard.clearContents()
        pasteboard.setString("**x** [[y]]", forType: .string)
        rig.tv.setSelectedRange(NSRange(location: 0, length: 0))
        request.pasteAsPlainText()
        #expect(rig.tv.string == "**x** [[y]] world\n")
        rig.tv.setSelectedRange(NSRange(location: 0, length: 0))
        request.paste()
        #expect(rig.tv.string.hasPrefix("**x** [[y]]**x** [[y]]"))
        request.selectAll()
        #expect(rig.tv.selectedRange() == NSRange(location: 0, length: (rig.tv.string as NSString).length))
    }

    @Test func pasteAsPlainTextIsOneUndoStep() throws {
        let rig = try rig("Hello\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("abc", forType: .string)
        let request = try request(on: "Hello", in: rig)
        request.pasteAsPlainText()
        #expect((rig.tv.string as NSString).contains("abc"))
        rig.tv.undoManager?.undo()
        #expect(rig.tv.string == "Hello\n")
    }

    @Test func closeReturnsTheKeyboardToTheEditor() throws {
        let rig = try rig("Hello\n")
        let request = try request(on: "Hello", in: rig)
        rig.window.makeFirstResponder(nil)
        request.close()
        #expect(rig.window.firstResponder === rig.tv)
    }

    // MARK: Other menus and no hook

    @Test func withoutTheHookTheSystemMenuStays() throws {
        let rig = try rig("Hello world\n")
        #expect(rig.tv.onTextMenu == nil)
        #expect(rig.tv.menu(for: try rightClick("Hello", in: rig)) != nil)
    }

    @Test func aReadOnlyEditorKeepsTheSystemMenu() throws {
        let rig = try rig("Hello world\n")
        rig.tv.isEditable = false
        rig.tv.onTextMenu = { _ in Issue.record("called") }
        #expect(rig.tv.menu(for: try rightClick("Hello", in: rig)) != nil)
    }

    @Test func aTaskBoxKeepsItsMenu() throws {
        let rig = try rig("Intro\n\n- [ ] a\n")
        var markers: [TaskMarkerMenuRequest] = []
        rig.tv.onTaskMarkerMenu = { markers.append($0) }
        rig.tv.onTextMenu = { _ in Issue.record("text menu took the task box") }
        let storage = try #require(rig.tv.textStorage)
        var box = NSRange(location: NSNotFound, length: 0)
        storage.enumerateAttribute(.taskCheckbox, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value != nil, box.location == NSNotFound { box = range }
        }
        let anchor = try #require(rig.tv.layoutBridge).boundingRect(forCharacterRange: box, in: try #require(rig.tv.textContainer))
        let style = rig.tv.configuration.taskCheckbox
        let size = TaskCheckboxGeometry.size(for: rig.tv.baseFont, style: style)
        let point = CGPoint(x: TaskCheckboxGeometry.boxX(contentX: anchor.minX, size: size, style: style) + size / 2 + rig.tv.textContainerOrigin.x,
                            y: anchor.midY + rig.tv.textContainerOrigin.y)
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: rig.tv.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: rig.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(rig.tv.menu(for: event) == nil)
        #expect(markers.count == 1)
    }

    @Test func aCalloutTitleKeepsItsMenu() throws {
        let rig = try rig("Intro\n\n> [!note] T\n> body\n")
        var callouts: [CalloutMenuRequest] = []
        rig.tv.onCalloutMenu = { callouts.append($0) }
        rig.tv.onTextMenu = { _ in Issue.record("text menu took the callout title") }
        let storage = try #require(rig.tv.textStorage)
        let line = try #require(storage.attribute(.calloutLine, at: 7, effectiveRange: nil) as? CalloutLine)
        let title = try #require(line.title)
        let lineRange = (storage.string as NSString).lineRange(for: NSRange(location: 7, length: 0))
        let rect = try #require(rig.tv.layoutBridge).boundingRect(forCharacterRange: lineRange, in: try #require(rig.tv.textContainer))
        let point = CGPoint(x: title.iconX + title.iconSize / 2 + rig.tv.textContainerOrigin.x, y: rect.midY + rig.tv.textContainerOrigin.y)
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: rig.tv.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: rig.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(rig.tv.menu(for: event) == nil)
        #expect(callouts.count == 1)
    }

    @Test func textInACalloutBodyGoesToTheTextMenu() throws {
        let rig = try rig("Intro\n\n> [!note] T\n> body\n")
        rig.tv.onCalloutMenu = { _ in Issue.record("callout menu took the body") }
        #expect(try request(on: "body", in: rig).blockKind == .quote)
    }
}

private extension NSRange {
    var upperBound: Int { NSMaxRange(self) }
}
#endif
