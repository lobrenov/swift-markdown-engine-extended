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
        for (needle, id) in [("word here", "w2"), ("word\n\n- item", "w7"), ("item word", "w5")] {
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

    /// Marks the whole of the text the hook is given, and records it.
    private final class Whole: @unchecked Sendable {
        private(set) var texts: [String] = []
        var hook: @Sendable (String) -> [TextMark] {
            { [self] text in
                texts.append(text)
                return [TextMark(range: 0..<text.utf16.count, id: "all", underline: .red, color: .blue)]
            }
        }
    }

    private func marked(_ attrs: [StyledRange], _ text: String, _ needle: String, offset: Int = 0) -> Bool {
        let id: String? = attribute(.markdownTextMark, in: attrs, at: (text as NSString).range(of: needle).location + offset)
        return id != nil
    }

    @Test("a list item's hook sees its content, not the marker or checkbox")
    func listContent() {
        let whole = Whole()
        let text = "- item word\n- [ ] task word\n1. num word\n"
        let attrs = style(text, marks: whole.hook)
        #expect(whole.texts == ["item word", "task word", "num word"])
        #expect(!marked(attrs, text, "- item"))
        #expect(marked(attrs, text, "item word"))
        #expect(!marked(attrs, text, "[ ] task"))
        #expect(marked(attrs, text, "task word"))
        #expect(!marked(attrs, text, "1. num"))
    }

    @Test("a mark that touches hidden syntax is dropped; one inside plain text keeps it hidden")
    func hiddenSyntaxIsNeverMarked() {
        let text = "a **word** here\n\n[word](http://x.y) b\n\n> word q\n\n# head\n"
        let whole = Whole()
        let wholeAttrs = style(text, marks: whole.hook)
        // `**word**`, `[word](url)` etc. in one mark over the whole paragraph: dropped.
        #expect(!marked(wholeAttrs, text, "a **word"))
        #expect(!marked(wholeAttrs, text, "[word]"))
        #expect(!marked(wholeAttrs, text, "> word"))
        #expect(!marked(wholeAttrs, text, "# head"))
        let inner = style(text) { t in
            guard let r = t.range(of: "word") else { return [] }
            let lower = t.utf16.distance(from: t.utf16.startIndex, to: r.lowerBound.samePosition(in: t.utf16)!)
            return [TextMark(range: lower..<(lower + 4), id: "w", color: .blue)]
        }
        #expect(marked(inner, text, "word", offset: 1))
        // The markers around it carry no mark, so their hiding is untouched.
        #expect(!marked(inner, text, "**word"))
        #expect(!marked(inner, text, "](http"))
        let quote: String? = attribute(.markdownTextMark, in: inner, at: (text as NSString).range(of: "> word").location)
        #expect(quote == nil)
    }

    @Test("a quoted list item's marker and a callout's type are not marked")
    func quoteSyntaxIsNeverMarked() {
        let text = "> - [ ] word q\n\n> [!note] Title word\n> body\n"
        let attrs = style(text, marks: Whole().hook)
        #expect(!marked(attrs, text, "> - [ ]"))
        #expect(!marked(attrs, text, "- [ ]"))
        #expect(!marked(attrs, text, "[!note]"))
        #expect(!marked(attrs, text, ">", offset: 0))
    }

    @Test("CRLF line endings and surrogate pairs keep the offsets right")
    func lineEndingsAndSurrogates() {
        let text = "a word\r\n\r\n😀 word\r\n"
        let attrs = style(text, marks: Marker().hook)
        let ns = text as NSString
        let first = ns.range(of: "word").location
        let second = ns.range(of: "word", options: .backwards).location
        let firstId: String? = attribute(.markdownTextMark, in: attrs, at: first)
        let secondId: String? = attribute(.markdownTextMark, in: attrs, at: second)
        #expect(firstId == "w2")
        #expect(secondId == "w3")
        let after: String? = attribute(.markdownTextMark, in: attrs, at: second + 4)
        #expect(after == nil)
    }

    @Test("a mark ends at its paragraph")
    func noLeak() {
        let text = "one word\n\nnext\n"
        let attrs = style(text, marks: Marker().hook)
        let next: String? = attribute(.markdownTextMark, in: attrs, at: (text as NSString).range(of: "next").location)
        #expect(next == nil)
    }

    @Test("bold adds the trait to the text's own font")
    func boldKeepsItalic() {
        let text = "an *word* here\n"
        let attrs = style(text, marks: Marker().hook)
        let font: PlatformFont? = attribute(.font, in: attrs, at: (text as NSString).range(of: "word").location)
        let traits = font?.fontDescriptor.symbolicTraits
        #expect(traits?.contains(.bold) == true)
        #expect(traits?.contains(.italic) == true)
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

    @Test("editing a marked word out removes its marks")
    func editingOutRemovesMark() {
        let text = "a word here\n\nnext\n"
        let (_, tv, window) = makeEditor(text, marks: Marker().hook)
        defer { window.contentView = nil }
        #expect(tv.textStorage?.attribute(.underlineColor, at: 2, effectiveRange: nil) != nil)
        tv.setSelectedRange(NSRange(location: 2, length: 4))
        tv.insertText("text", replacementRange: NSRange(location: 2, length: 4))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        #expect(tv.string == "a text here\n\nnext\n")
        #expect(tv.textStorage?.attribute(.underlineColor, at: 2, effectiveRange: nil) == nil)
        #expect(tv.textStorage?.attribute(.markdownTextMark, at: 2, effectiveRange: nil) == nil)
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
