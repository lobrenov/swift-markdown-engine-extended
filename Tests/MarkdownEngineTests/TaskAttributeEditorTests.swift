//
//  TaskAttributeEditorTests.swift
//  MarkdownEngineTests
//
//  Fork: a task line's `>YYYY-MM-DD` and `@[[Title]]` drawn as pills off the caret's line, their `.date` and
//  `.parent` queries, and the click on a drawn pill.
//

import Foundation
import SwiftUI
import Testing
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
@testable import MarkdownEngine
@testable import MarkdownEngineSyntax

private struct KnownTitles: WikiLinkResolver {
    func resolve(displayName: String, range: NSRange) -> WikiLinkResolution? {
        displayName == "Ta Da" ? WikiLinkResolution(id: "1", exists: true) : nil
    }
}

private enum Chips {
    static let style = TaskAttributeStyle(
        due: { date in TaskAttributeChip(label: date == "2026-10-02" ? "Today" : "Fri", tint: .systemBlue) },
        parent: { title, resolution in
            TaskAttributeChip(label: title, tint: resolution == nil ? .systemGray : .systemPurple,
                              strikethrough: resolution == nil, drawIcon: { _, _ in })
        })

    static func configuration(on: Bool = true) -> MarkdownEditorConfiguration {
        var config = MarkdownEditorConfiguration.default
        config.services = MarkdownEditorServices(wikiLinks: KnownTitles())
        if on { config.taskAttributes = style }
        return config
    }
}

@Suite("Fork — task attribute styling")
struct TaskAttributeStylingTests {

    private static let text = "- [ ] call >2026-10-02 @[[Ta Da]] >2026-10-03 @[[Gone]]\nnext"

    private func styled(_ text: String = Self.text, caret: Int = -1, on: Bool = true) -> [StyledRange] {
        MarkdownASTStyler.styleAttributes(text: text, fontName: PlatformFont.systemFont(ofSize: 14).fontName, fontSize: 14,
                                          caretLocation: caret, configuration: Chips.configuration(on: on))
    }

    private func spans(_ attrs: [StyledRange]) -> [(range: NSRange, span: TaskAttributeSpan)] {
        attrs.compactMap { entry in (entry.attributes[.markdownTaskAttribute] as? TaskAttributeSpan).map { (entry.range, $0) } }
    }

    @Test func offTheCaretsLineTheFirstOfEachKindIsAPillOverItsSource() {
        let found = spans(styled(caret: 56))
        #expect(found.map(\.range) == [NSRange(location: 11, length: 11), NSRange(location: 23, length: 10)])
        #expect(found.map(\.span.kind) == [.due, .parent])
        #expect(found.map(\.span.source) == [">2026-10-02", "@[[Ta Da]]"])
        #expect(found.map(\.span.chip.label) == ["Today", "Ta Da"])
    }

    @Test func theChipsClosureSeesTheBareTitleAndTheResolverAnswer() {
        let text = "- [ ] a @[[Gone]]\n- [ ] b @[[Projects/Ta Da#Part|alias]]\nnext"
        let found = spans(styled(text, caret: (text as NSString).length - 1))
        #expect(found.map(\.span.chip.label) == ["Gone", "Ta Da"])
        #expect(found[0].span.chip.strikethrough && found[1].span.chip.strikethrough, "the resolver knows `Ta Da` by its name, not its folder")
    }

    @Test func attributesInsideEmphasisAreDrawn() {
        let found = spans(styled("- [ ] **a >2026-10-02** ==b @[[Ta Da]]==\nnext", caret: 44))
        #expect(found.map(\.span.kind) == [.due, .parent])
    }

    @Test func theStylesFingerprintJoinsTheResolversInTheWrappersComparison() {
        let box = Box()
        var config = Chips.configuration()
        config.taskAttributes?.fingerprint = { box.value }
        let before = config.linkStyleFingerprint
        box.value = 1
        #expect(config.linkStyleFingerprint != before)
        #expect(Chips.configuration(on: false).linkStyleFingerprint != Chips.configuration().linkStyleFingerprint)
    }

    private final class Box: @unchecked Sendable { var value: AnyHashable = 0 }

    @Test func theSourceIsHiddenAndItsFirstCharacterReservesThePillsWidth() {
        let attrs = styled(caret: 56)
        let (range, span) = spans(attrs)[0]
        let hidden = (attrs.last { $0.range == range && $0.attributes[.foregroundColor] != nil }?.attributes[.foregroundColor]) as? PlatformColor
        #expect(hidden == PlatformColor.clear)
        func kern(_ location: Int) -> CGFloat? {
            attrs.last { $0.range == NSRange(location: location, length: 1) && $0.attributes[.kern] != nil }?.attributes[.kern] as? CGFloat
        }
        #expect(span.width > 12)
        #expect(kern(range.location)! > 0)
        #expect(kern(range.location + 1)! < 0 && kern(NSMaxRange(range) - 1)! < 0)
    }

    @Test func onTheCaretsLineTheSourceIsPlain() {
        let attrs = styled(caret: 10)
        #expect(spans(attrs).isEmpty)
        // A parent's `[[ ]]` is a wiki link there.
        #expect(attrs.contains { $0.range == NSRange(location: 26, length: 5) && $0.attributes[.link] as? String == "Ta Da" })
    }

    @Test func withoutTheConfigurationTheyStayText() {
        #expect(spans(styled(caret: 56, on: false)).isEmpty)
        let plain = styled(caret: 56, on: false)
        #expect(plain.contains { $0.range == NSRange(location: 26, length: 5) && $0.attributes[.link] as? String == "Ta Da" })
    }

    @Test func notOnOtherLines() {
        #expect(spans(styled("- plain >2026-10-02 @[[Ta Da]]\n\nProse >2026-10-02\n\n> q >2026-10-02", caret: -1)).isEmpty)
    }
}

#if os(macOS)
@MainActor
@Suite("Fork — task attribute queries and clicks")
struct TaskAttributeQueryTests {

    private final class Recorder {
        var text = ""
        var states: [SlashCommandState?] = []
        var last: SlashCommandState? { states.last ?? nil }
    }

    private func makeEditor(_ text: String, _ recorder: Recorder, triggers: Set<SlashCommandState.Trigger>? = [.date, .parent])
        -> (NativeTextView, SlashCommandProxy) {
        _ = NSApplication.shared
        recorder.text = text
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        textView.isEditable = true
        textView.allowsUndo = true
        textView.configuration = Chips.configuration()
        let coordinator = NativeTextViewCoordinator(
            text: Binding(get: { recorder.text }, set: { recorder.text = $0 }), fontName: "SF Pro Text", fontSize: 14,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        coordinator.configuration = textView.configuration
        coordinator.documentId = "A"
        coordinator.textView = textView
        coordinator.onSlashCommandChange = { recorder.states.append($0) }
        textView.delegate = coordinator
        textView.string = text
        coordinator.lastSyncedText = text
        coordinator.lastComputedStorage = text
        coordinator.previousDisplayLength = (text as NSString).length
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        objc_setAssociatedObject(textView, &Self.coordinatorKey, coordinator, .OBJC_ASSOCIATION_RETAIN)
        let proxy = SlashCommandProxy()
        proxy.coordinator = coordinator
        if let triggers { proxy.triggers = SlashCommandState.Trigger.defaults.union(triggers) }
        return (textView, proxy)
    }
    private static var coordinatorKey = 0

    private func type(_ tv: NSTextView, _ text: String) async throws {
        for character in text { tv.insertText(String(character), replacementRange: tv.selectedRange()) }
        try await Task.sleep(for: .milliseconds(30))
    }

    // MARK: Date

    @Test func greaterThanAfterWhitespaceOnATaskLineOpensADateQuery() async throws {
        let recorder = Recorder()
        let (tv, _) = makeEditor("- [ ] call ", recorder)
        try await type(tv, ">fri")
        let state = try #require(recorder.last)
        #expect(state.trigger == .date && state.query == "fri")
        #expect(state.range == NSRange(location: 11, length: 4))
        #expect(!state.isAtLineStart)
    }

    @Test func aDateQueryHoldsWordsDigitsAndTwoSpaces() async throws {
        let recorder = Recorder()
        let (tv, _) = makeEditor("1. [x] call ", recorder)
        try await type(tv, ">in 3 days")
        #expect(recorder.last?.query == "in 3 days")
        try await type(tv, " ")
        #expect(recorder.states.last! == nil)
    }

    @Test func aDateQueryEndsAtPunctuationOrASpaceAfterTheArrow() async throws {
        let recorder = Recorder()
        let (tv, _) = makeEditor("- [ ] a ", recorder)
        try await type(tv, ">fri")
        try await type(tv, ",")
        #expect(recorder.states.last! == nil)

        let spaced = Recorder()
        let (other, _) = makeEditor("- [ ] a ", spaced)
        try await type(other, "> b")
        #expect(spaced.last == nil)
        try await type(other, "2026-10-02")
        #expect(spaced.last == nil)
    }

    @Test func aDateQueryReadsADateAsTyped() async throws {
        let recorder = Recorder()
        let (tv, _) = makeEditor("- [ ] a ", recorder)
        try await type(tv, ">2026-10-0")
        #expect(recorder.last?.query == "2026-10-0")
    }

    @Test func greaterThanOpensNothingElsewhere() async throws {
        for text in ["- a ", "a ", "- [ ] a", "\n", "- [ ]", "- [ ] a\n", "> - [ ] a ", "    code "] {
            let recorder = Recorder()
            let (tv, _) = makeEditor(text, recorder)
            try await type(tv, ">fri")
            #expect(recorder.states.compactMap { $0 }.isEmpty, "\(text.debugDescription)")
        }
        let atStart = Recorder()
        let (tv, _) = makeEditor("- [ ] a\n", atStart)
        try await type(tv, ">fri")
        #expect(atStart.states.compactMap { $0 }.isEmpty)
    }

    @Test func theTriggersAreOptIn() async throws {
        let recorder = Recorder()
        let (tv, _) = makeEditor("- [ ] a ", recorder, triggers: nil)
        try await type(tv, ">fri @ta")
        #expect(recorder.states.compactMap { $0 }.isEmpty)
        #expect(!SlashCommandState.Trigger.defaults.contains(.date) && !SlashCommandState.Trigger.defaults.contains(.parent))
    }

    @Test func insertReplacesTheWholeDateTokenAsOneUndoStep() async throws {
        let recorder = Recorder()
        let (tv, proxy) = makeEditor("- [ ] call ", recorder)
        try await type(tv, ">fri")
        proxy.insert(">2026-10-02 ", selecting: NSRange(location: 12, length: 0))
        try await Task.sleep(for: .milliseconds(30))
        #expect(tv.string == "- [ ] call >2026-10-02 ")
        #expect(tv.selectedRange() == NSRange(location: 23, length: 0))
        #expect(recorder.text == "- [ ] call >2026-10-02 ")
        #expect(recorder.states.last! == nil)
        tv.undoManager?.undo()
        #expect(tv.string == "- [ ] call >fri")
        tv.undoManager?.redo()
        #expect(tv.string == "- [ ] call >2026-10-02 ")
    }

    // MARK: Parent

    @Test func atAfterWhitespaceOnATaskLineOpensAParentQuery() async throws {
        let recorder = Recorder()
        let (tv, _) = makeEditor("- [ ] move ", recorder)
        try await type(tv, "@ta")
        let state = try #require(recorder.last)
        #expect(state.trigger == .parent && state.query == "ta")
        #expect(state.range == NSRange(location: 11, length: 3))
        try await type(tv, " da")
        #expect(recorder.last?.query == "ta da")
    }

    @Test func aParentQueryEndsAtASpaceAfterTheAtOrALinkStop() async throws {
        let recorder = Recorder()
        let (tv, _) = makeEditor("- [ ] a ", recorder)
        try await type(tv, "@ b")
        #expect(recorder.last == nil)
        let stops = Recorder()
        let (other, _) = makeEditor("- [ ] a ", stops)
        try await type(other, "@ta")
        try await type(other, "|")
        #expect(stops.states.last! == nil)
    }

    @Test func typingTheBracketsAfterAtKeepsTheParentQuery() async throws {
        let recorder = Recorder()
        let (tv, _) = makeEditor("- [ ] move ", recorder)
        try await type(tv, "@[[ta")
        #expect(tv.string == "- [ ] move @[[ta]]")
        let state = try #require(recorder.last)
        #expect(state.trigger == .parent && state.query == "ta")
        #expect(state.range == NSRange(location: 11, length: 5))
    }

    @Test func atOpensNothingOffATaskLineOrInsideAWord() async throws {
        for text in ["- a ", "Mail ", "- [ ] mail"] {
            let recorder = Recorder()
            let (tv, _) = makeEditor(text, recorder)
            try await type(tv, "@ta")
            #expect(recorder.states.compactMap { $0 }.isEmpty, "\(text.debugDescription)")
        }
    }

    @Test func aLinkQueryAfterABareAtIsStillALinkQuery() async throws {
        let recorder = Recorder()
        let (tv, _) = makeEditor("- [ ] a ", recorder, triggers: [.date])
        try await type(tv, "@[[ta")
        #expect(recorder.last?.trigger == .link)
    }

    @Test func insertReplacesTheWholeParentTokenAsOneUndoStep() async throws {
        let recorder = Recorder()
        let (tv, proxy) = makeEditor("- [ ] move ", recorder)
        try await type(tv, "@ta")
        proxy.insert("@[[Ta Da MVP]] ", selecting: NSRange(location: 15, length: 0))
        try await Task.sleep(for: .milliseconds(30))
        #expect(tv.string == "- [ ] move @[[Ta Da MVP]] ")
        #expect(tv.selectedRange() == NSRange(location: 26, length: 0))
        tv.undoManager?.undo()
        #expect(tv.string == "- [ ] move @ta")
    }

    @Test func insertAlsoReplacesTheClosersTypedBrackets() async throws {
        let recorder = Recorder()
        let (tv, proxy) = makeEditor("- [ ] move ", recorder)
        try await type(tv, "@[[ta")
        proxy.insert("@[[Ta Da MVP]] ", selecting: NSRange(location: 15, length: 0))
        try await Task.sleep(for: .milliseconds(30))
        #expect(tv.string == "- [ ] move @[[Ta Da MVP]] ")
        tv.undoManager?.undo()
        #expect(tv.string == "- [ ] move @[[ta]]")
    }

    // MARK: Click

    private func laidOut(_ text: String, caret: Int) throws -> (tv: NativeTextView, window: NSWindow, coordinator: NativeTextViewCoordinator) {
        _ = NSApplication.shared
        let config = Chips.configuration()
        let coordinator = NativeTextViewCoordinator(
            text: .constant(text), fontName: "SF Pro", fontSize: 14,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        coordinator.configuration = config
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.configuration = config
        tv.isEditable = true
        tv.allowsUndo = true
        tv.delegate = coordinator
        let scrollView = NSScrollView(frame: tv.frame)
        scrollView.documentView = tv
        let window = NSWindow(contentRect: tv.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scrollView
        let layoutDelegate = MarkdownLayoutManagerDelegate()
        coordinator.layoutDelegate = layoutDelegate
        try #require(tv.textLayoutManager).delegate = layoutDelegate
        let bridge = LayoutBridge(try #require(tv.textLayoutManager))
        coordinator.layoutBridge = bridge
        tv.layoutBridge = bridge
        coordinator.textView = tv
        coordinator.rebuildTextStorageAndStyle(tv, from: text)
        coordinator.lastSyncedText = text
        coordinator.lastComputedStorage = text
        coordinator.previousDisplayLength = (text as NSString).length
        tv.setSelectedRange(NSRange(location: caret, length: 0))
        return (tv, window, coordinator)
    }

    @Test func aDrawnPillIsHitWhereItIsDrawnAndReplacesItsSource() throws {
        let text = "- [ ] call >2026-10-02 now\nnext"
        let (tv, window, coordinator) = try laidOut(text, caret: 28)
        let storage = try #require(tv.textStorage)
        #expect(storage.attribute(.markdownTaskAttribute, at: 11, effectiveRange: nil) is TaskAttributeSpan)

        let bridge = try #require(tv.layoutBridge)
        let container = try #require(tv.textContainer)
        let first = bridge.boundingRect(forCharacterRange: NSRange(location: 11, length: 1), in: container)
        let inside = CGPoint(x: first.minX + 20 + tv.textContainerOrigin.x, y: first.midY + tv.textContainerOrigin.y)
        let hit = try #require(tv.taskAttributeHit(atViewPoint: inside))
        #expect(hit.range == NSRange(location: 11, length: 11) && hit.span.kind == .due)
        #expect(tv.taskAttributeHit(atViewPoint: CGPoint(x: 2, y: inside.y)) == nil)

        let click = tv.taskAttributeClick(for: hit)
        #expect(click.source == ">2026-10-02" && click.kind == .due && click.range == hit.range)
        click.replace(">2026-10-09")
        #expect(tv.string == "- [ ] call >2026-10-09 now\nnext")
        tv.undoManager?.undo()
        #expect(tv.string == text)
        // A stale click does nothing.
        tv.string = "- [ ] call >2026-10-03 now\nnext"
        click.replace(">2026-11-01")
        #expect(tv.string == "- [ ] call >2026-10-03 now\nnext")
        withExtendedLifetime((window, coordinator)) {}
    }

    @Test func thePillIsPaintedInTheReservedRoom() throws {
        let (tv, window, coordinator) = try laidOut("- [ ] call >2026-10-02 now\nnext", caret: 28)
        window.contentView?.layoutSubtreeIfNeeded()
        let bridge = try #require(tv.layoutBridge)
        let container = try #require(tv.textContainer)
        let first = bridge.boundingRect(forCharacterRange: NSRange(location: 11, length: 1), in: container)
        let hit = try #require(tv.taskAttributeHit(atViewPoint: CGPoint(x: first.minX + 20 + tv.textContainerOrigin.x,
                                                                         y: first.midY + tv.textContainerOrigin.y)))
        let image = try #require(tv.bitmapImageRepForCachingDisplay(in: tv.bounds))
        tv.cacheDisplay(in: tv.bounds, to: image)
        let scale = CGFloat(image.pixelsWide) / tv.bounds.width
        func color(at point: CGPoint) -> NSColor? {
            image.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB)
        }
        // Left of the label, inside the pill's padding: the blue fill, not the white page and not hidden text.
        let probe = color(at: CGPoint(x: hit.rect.minX + 2, y: hit.rect.midY))
        let blue = try #require(probe).blueComponent, red = try #require(probe).redComponent
        #expect(blue > red + 0.05, "\(String(describing: probe))")
        withExtendedLifetime((window, coordinator)) {}
    }

    @Test func onTheCaretsLineThereIsNoPillToHit() throws {
        let (tv, window, coordinator) = try laidOut("- [ ] call >2026-10-02 now\nnext", caret: 3)
        let storage = try #require(tv.textStorage)
        #expect(storage.attribute(.markdownTaskAttribute, at: 11, effectiveRange: nil) == nil)
        #expect(tv.taskAttributeHit(atViewPoint: CGPoint(x: 100, y: 12)) == nil)
        withExtendedLifetime((window, coordinator)) {}
    }
}
#endif
