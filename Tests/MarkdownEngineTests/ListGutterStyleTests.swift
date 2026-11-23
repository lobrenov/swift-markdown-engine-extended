//
//  ListGutterStyleTests.swift
//  MarkdownEngineTests
//
//  Fork: which list items `ListStyle.gutterPrefix` is offered, and what the styler marks, on both platforms.
//

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Fork — list gutter styling")
struct ListGutterStyleTests {
    private let size: CGFloat = 14

    /// Offers every item, labelling it with the marker it was called with.
    private static let labelsMarker: @Sendable (String, String) -> ListGutterPrefix? = { marker, _ in
        ListGutterPrefix(length: 0, label: marker)
    }

    private func style(_ text: String, caret: Int = -1, selection: NSRange? = nil,
                       gutter: (@Sendable (String, String) -> ListGutterPrefix?)? = labelsMarker) -> [StyledRange] {
        var config = MarkdownEditorConfiguration.default
        config.lists.gutterPrefix = gutter
        let font = PlatformFont.systemFont(ofSize: size)
        return MarkdownASTStyler.styleAttributes(text: text, fontName: font.fontName, fontSize: size,
                                                 caretLocation: caret, selection: selection, configuration: config)
    }

    private func attribute<T>(_ key: NSAttributedString.Key, in attrs: [StyledRange], at pos: Int) -> T? {
        var result: T?
        for (range, values) in attrs where NSLocationInRange(pos, range) {
            if let value = values[key] as? T { result = value }
        }
        return result
    }

    private func label(_ attrs: [StyledRange], _ text: String, _ needle: String) -> String? {
        attribute(.listGutterLabel, in: attrs, at: (text as NSString).range(of: needle).location)
    }

    @Test("top-level plain and ordered items are offered; tasks, quotes, nested items and bare markers are not")
    func exclusions() {
        let text = "* a\n- [ ] b\n- [/] c\n\n> * d\n\n* e\n\t* f\n\n1. g\n\n2) h\n\n*\n"
        let attrs = style(text)
        #expect(label(attrs, text, "* a") == "*")
        #expect(label(attrs, text, "* e") == "*")
        #expect(label(attrs, text, "1. g") == "1.")
        #expect(label(attrs, text, "2) h") == "2)")
        #expect(label(attrs, text, "- [ ]") == nil)
        #expect(label(attrs, text, "- [/]") == nil)
        #expect(label(attrs, text, "* d") == nil)
        #expect(label(attrs, text, "* f") == nil)
        #expect(label(attrs, text, "\t* f") == nil)
        #expect(label(attrs, text, "*\n") == nil)
    }

    @Test("an item whose prefix the hook declines is an ordinary item")
    func declined() {
        let text = "* a\n"
        let attrs = style(text) { _, _ in nil }
        #expect(label(attrs, text, "* a") == nil)
        let bullet: Bool? = attribute(.bulletMarker, in: attrs, at: 0)
        #expect(bullet == true)
    }

    @Test("the caret or a selection in the marker or prefix reveals the source")
    func reveal() {
        let text = "1. a\n\n* b\n"
        #expect(label(style(text, caret: 9), text, "* b") != nil)
        #expect(label(style(text, caret: 3), text, "1. a") == nil)
        #expect(label(style(text, selection: NSRange(location: 0, length: 6)), text, "1. a") == nil)
    }

    @Test("without the hook nothing is marked and bullets draw as before")
    func inertWhenUnset() {
        let text = "* a\n\n1. b\n"
        let attrs = style(text, gutter: nil)
        #expect(label(attrs, text, "* a") == nil)
        #expect(label(attrs, text, "1. b") == nil)
        let caretKey: Int? = attribute(.listGutterCaret, in: attrs, at: 0)
        #expect(caretKey == nil)
        let bullet: Bool? = attribute(.bulletMarker, in: attrs, at: 0)
        #expect(bullet == true)
    }

    @Test("an emphasized prefix applies at any depth")
    func emphasizedAtAnyDepth() {
        var config = MarkdownEditorConfiguration.default
        config.lists.emphasizedPrefix = { _ in 1 }
        let font = PlatformFont.systemFont(ofSize: size)
        let text = "- a\n\t- b\n"
        let attrs = MarkdownASTStyler.styleAttributes(text: text, fontName: font.fontName, fontSize: size,
                                                      configuration: config)
        for needle in ["a", "b"] {
            let f: PlatformFont? = attribute(.font, in: attrs, at: (text as NSString).range(of: needle).location)
            #expect(f?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        }
    }
}
