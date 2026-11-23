//
//  TextMarkTests.swift
//  MarkdownEngineTests
//
//  Fork: `MarkdownEditorConfiguration.textMarks` marks spans as attributes only, and `onTextMarkClick` reports a click.
//

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import SwiftUI
import Testing
@testable import MarkdownEngine

/// Marks every `word` in the text it is given, and counts its calls.
private final class Marker: @unchecked Sendable {
    private(set) var calls = 0
    private let lock = NSLock()

    var hook: @Sendable (String) -> [TextMark] {
        { [self] text in
            lock.lock(); calls += 1; lock.unlock()
            var marks: [TextMark] = []
            var from = text.startIndex
            while let found = text.range(of: "word", range: from..<text.endIndex) {
                let lower = text.utf16.distance(from: text.utf16.startIndex, to: found.lowerBound.samePosition(in: text.utf16)!)
                marks.append(TextMark(range: lower..<(lower + 4), id: "w\(lower)", underline: .red, color: .blue, bold: true))
                from = found.upperBound
            }
            return marks
        }
    }
}

@MainActor
@Suite("Fork — text marks")
struct TextMarkTests {
    private let size: CGFloat = 14

    private func style(_ text: String, marks: (@Sendable (String) -> [TextMark])?) -> [StyledRange] {
        var config = MarkdownEditorConfiguration.default
        config.textMarks = marks
        let font = PlatformFont.systemFont(ofSize: size)
        return MarkdownASTStyler.styleAttributes(text: text, fontName: font.fontName, fontSize: size,
                                                 configuration: config)
    }

    private func attribute<T>(_ key: NSAttributedString.Key, in attrs: [StyledRange], at pos: Int) -> T? {
        var result: T?
        for (range, values) in attrs where NSLocationInRange(pos, range) {
            if let value = values[key] as? T { result = value }
        }
        return result
    }

    @Test("a mark is attributes over its span, in paragraphs, headings and list items")
    func marksApply() {
        let text = "a word here\n\n# head word\n\n- item word\n"
        let marker = Marker()
        let attrs = style(text, marks: marker.hook)
        for (needle, id) in [("word here", "w2"), ("word\n\n- item", "w7"), ("item word", "w7")] {
            let at = (text as NSString).range(of: needle).location + (needle == "item word" ? 5 : 0)
            let found: String? = attribute(.markdownTextMark, in: attrs, at: at)
            #expect(found == id)
        }
        let first = (text as NSString).range(of: "word").location
        let color: PlatformColor? = attribute(.foregroundColor, in: attrs, at: first)
        let underline: Int? = attribute(.underlineStyle, in: attrs, at: first)
        let underlineColor: PlatformColor? = attribute(.underlineColor, in: attrs, at: first)
        let font: PlatformFont? = attribute(.font, in: attrs, at: first)
        #expect(color == .blue)
        #expect(underline == NSUnderlineStyle.single.rawValue)
        #expect(underlineColor == .red)
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        let outside: String? = attribute(.markdownTextMark, in: attrs, at: 0)
        #expect(outside == nil)
    }

    @Test("a mark inside a code span is dropped")
    func codeExcluded() {
        let text = "a `word` and word\n\n```\nword\n```\n"
        let attrs = style(text, marks: Marker().hook)
        let ns = text as NSString
        let inSpan: String? = attribute(.markdownTextMark, in: attrs, at: ns.range(of: "word").location)
        let outside: String? = attribute(.markdownTextMark, in: attrs, at: ns.range(of: "word", options: .backwards,
                                                                                  range: NSRange(location: 0, length: 18)).location)
        let inFence: String? = attribute(.markdownTextMark, in: attrs, at: ns.range(of: "word\n```").location)
        #expect(inSpan == nil)
        #expect(outside != nil)
        #expect(inFence == nil)
    }

    @Test("a range outside the text is dropped")
    func badRanges() {
        let attrs = style("abc\n") { _ in [TextMark(range: 2..<9, id: "x"), TextMark(range: 1..<1, id: "y")] }
        #expect(!attrs.contains { $0.attributes[.markdownTextMark] != nil })
    }

    @Test("without the hook there are no mark attributes")
    func inertWhenUnset() {
        let attrs = style("a word here\n", marks: nil)
        #expect(!attrs.contains { $0.attributes[.markdownTextMark] != nil || $0.attributes[.underlineColor] != nil })
    }

    @Test("the hook runs once per block in scope, not per document")
    func scoped() {
        let text = "one word\n\ntwo word\n\nthree word\n"
        let marker = Marker()
        var config = MarkdownEditorConfiguration.default
        config.textMarks = marker.hook
        let font = PlatformFont.systemFont(ofSize: size)
        _ = MarkdownASTStyler.styleAttributes(text: text, fontName: font.fontName, fontSize: size,
                                              scopedRanges: [NSRange(location: 10, length: 8)], configuration: config)
        #expect(marker.calls == 1)
    }

#if os(macOS)
    private final class Retained {
        var bridge: LayoutBridge?
        let layoutDelegate = MarkdownLayoutManagerDelegate()
    }
    private let retained = Retained()

    private func makeEditor(_ text: String, marks: @escaping @Sendable (String) -> [TextMark])
        -> (NativeTextViewCoordinator, NativeTextView, NSWindow) {
        _ = NSApplication.shared
        let coordinator = NativeTextViewCoordinator(
            text: .constant(text), fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        coordinator.configuration.textMarks = marks
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.configuration = coordinator.configuration
        tv.isEditable = true
        if let tlm = tv.textLayoutManager {
            tlm.delegate = retained.layoutDelegate
            retained.bridge = LayoutBridge(tlm)
            tv.layoutBridge = retained.bridge
            coordinator.layoutBridge = retained.bridge
        }
        tv.delegate = coordinator
        coordinator.textView = tv
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = tv
        window.makeFirstResponder(tv)
        coordinator.rebuildTextStorageAndStyle(tv, from: text)
        coordinator.lastSyncedText = text
        coordinator.lastComputedStorage = text
        coordinator.previousDisplayLength = (text as NSString).length
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.textLayoutManager?.ensureLayout(for: tv.textLayoutManager!.documentRange)
        return (coordinator, tv, window)
    }

    @Test("marks follow an edit, and the text is unchanged")
    func marksUpdateAfterEdit() {
        let text = "plain text\n"
        let (_, tv, window) = makeEditor(text, marks: Marker().hook)
        defer { window.contentView = nil }
        #expect(tv.textStorage?.attribute(.markdownTextMark, at: 0, effectiveRange: nil) == nil)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.insertText("word ", replacementRange: NSRange(location: 0, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        #expect(tv.string == "word plain text\n")
        #expect(tv.textStorage?.attribute(.markdownTextMark, at: 0, effectiveRange: nil) as? String == "w0")
        #expect(tv.textStorage?.attribute(.markdownTextMark, at: 6, effectiveRange: nil) == nil)
    }

    /// `mouseDown` reports `textMarkHit` and then falls through to AppKit's click tracking, which a headless test
    /// can't drive; this pins the hit test it reports from.
    @Test("a point over a mark hits its id, and one elsewhere hits none")
    func hitTest() throws {
        let text = "plain word here\n"
        let (_, tv, window) = makeEditor(text, marks: Marker().hook)
        defer { window.contentView = nil }
        let bridge = try #require(tv.layoutBridge)
        let container = try #require(tv.textContainer)
        func point(_ index: Int) -> CGPoint {
            let rect = bridge.boundingRect(forCharacterRange: NSRange(location: index, length: 1), in: container)
            return CGPoint(x: rect.midX + tv.textContainerOrigin.x, y: rect.midY + tv.textContainerOrigin.y)
        }
        #expect(tv.textMarkHit(atViewPoint: point(7)) == "w6")
        #expect(tv.textMarkHit(atViewPoint: point(1)) == nil)
        #expect(tv.textMarkHit(atViewPoint: point(13)) == nil)
        tv.configuration.textMarks = nil
        #expect(tv.textMarkHit(atViewPoint: point(7)) == nil)
    }
#endif
}
