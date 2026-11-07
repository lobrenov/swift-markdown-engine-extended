//
//  ListTypographyTests.swift
//  MarkdownEngineTests
//
//  Fork: list geometry (task box on the bullet's slot, a bare bullet's room, the first level's indent),
//  the space typed after a bare bullet, and the typing font at the caret.
//

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Fork — list typography")
struct ListTypographyTests {
    private let size: CGFloat = 14
    private var baseFont: PlatformFont { .systemFont(ofSize: size) }

    private func width(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: baseFont]).width
    }

    private func style(_ text: String, caret: Int = -1,
                       configure: (inout MarkdownEditorConfiguration) -> Void = { _ in }) -> [StyledRange] {
        var config = MarkdownEditorConfiguration.default
        configure(&config)
        return MarkdownASTStyler.styleAttributes(text: text, fontName: baseFont.fontName, fontSize: size,
                                                 caretLocation: caret, configuration: config)
    }

    private func attribute<T>(_ key: NSAttributedString.Key, in attrs: [StyledRange], at pos: Int) -> T? {
        var result: T?
        for (range, values) in attrs where NSLocationInRange(pos, range) {
            if let value = values[key] as? T { result = value }
        }
        return result
    }

    @Test func aTaskBoxCentresOnTheBulletSlot() throws {
        // "- [ ] t": marker 0, spacer 1 (kerned), box 2..4 and gap 5 collapsed, content 6.
        let attrs = style("- [ ] t")
        let paragraph: NSParagraphStyle = try #require(attribute(.paragraphStyle, in: attrs, at: 0))
        let kern: CGFloat = attribute(.kern, in: attrs, at: 1) ?? 0
        let checkbox = MarkdownEditorConfiguration.default.taskCheckbox
        let box = TaskCheckboxGeometry.size(for: baseFont, style: checkbox)
        let contentX = paragraph.firstLineHeadIndent + width("- ") + kern
        let boxCentre = TaskCheckboxGeometry.boxX(contentX: contentX, size: box, style: checkbox) + box / 2
        // Collapsed box characters add a sliver of advance.
        #expect(abs(boxCentre - (paragraph.firstLineHeadIndent + width("-") / 2)) < 1)
    }

    @Test func aBareBulletEndsASpaceWider() {
        #expect(attribute(.kern, in: style("-"), at: 0) == width(" "))
        #expect(attribute(.kern, in: style("+"), at: 0) == width(" "))
        #expect((attribute(.kern, in: style("*"), at: 0) as CGFloat?) == nil)
        #expect((attribute(.kern, in: style("- a"), at: 0) as CGFloat?) == nil)
    }

    @Test func firstLevelIndentSetsTheTopLevelAndNestsFromIt() throws {
        let configure: (inout MarkdownEditorConfiguration) -> Void = { $0.lists.firstLevelIndent = 4 }
        let top: NSParagraphStyle = try #require(attribute(.paragraphStyle, in: style("- a", configure: configure), at: 0))
        #expect(top.firstLineHeadIndent == 4)
        #expect(abs(top.headIndent - (4 + width("- "))) < 0.01)
        let per = MarkdownEditorConfiguration.default.lists.indentPerLevel
        let nested: NSParagraphStyle = try #require(attribute(.paragraphStyle, in: style("- a\n\t- b", configure: configure), at: 5))
        #expect(nested.tabStops.first?.location == 4 + per)
        #expect(abs(nested.headIndent - (4 + per + width("- "))) < 0.01)
        // Unset, the first level is one level's indent.
        let plain: NSParagraphStyle = try #require(attribute(.paragraphStyle, in: style("- a"), at: 0))
        #expect(plain.firstLineHeadIndent == per)
    }

    @Test func theTypingFontIsTheVisibleTextsBeforeTheCaret() {
        let heading = PlatformFont.boldSystemFont(ofSize: 24)
        let hidden = PlatformFont.systemFont(ofSize: 0.1)
        let text = NSMutableAttributedString(string: "## Head\n**", attributes: [.font: baseFont])
        text.addAttribute(.font, value: heading, range: NSRange(location: 0, length: 7))
        text.addAttribute(.font, value: hidden, range: NSRange(location: 8, length: 2))
        #expect(TextStylingService.typingFont(at: 7, in: text, base: baseFont) == heading)
        #expect(TextStylingService.typingFont(at: 8, in: text, base: baseFont) == baseFont)
        #expect(TextStylingService.typingFont(at: 10, in: text, base: baseFont) == baseFont)
        #expect(TextStylingService.typingFont(at: 0, in: text, base: baseFont) == baseFont)
    }

    #if os(macOS)
    private func makeEditor(_ text: String = "") -> NativeTextView {
        _ = NSApplication.shared
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        textView.isEditable = true
        textView.allowsUndo = true
        textView.configuration = .default
        let coordinator = NativeTextViewCoordinator(
            text: .constant(text), fontName: baseFont.fontName, fontSize: size,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        coordinator.textView = textView
        textView.delegate = coordinator
        coordinator.rebuildTextStorageAndStyle(textView, from: text)
        coordinator.lastSyncedText = text
        coordinator.lastComputedStorage = text
        coordinator.previousDisplayLength = (text as NSString).length
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        objc_setAssociatedObject(textView, &Self.coordinatorKey, coordinator, .OBJC_ASSOCIATION_RETAIN)
        return textView
    }
    private static var coordinatorKey = 0

    /// The text with `|` at the caret after typing `typed` into `text`.
    private func typed(_ typed: String, into text: String = "") -> String {
        let tv = makeEditor(text)
        for character in typed { tv.insertText(String(character), replacementRange: tv.selectedRange()) }
        return (tv.string as NSString).replacingCharacters(in: tv.selectedRange(), with: "|")
    }

    @Test func typingAfterABareBulletAddsTheSpace() {
        #expect(typed("-a") == "- a|")
        #expect(typed("+a") == "+ a|")
        #expect(typed("-[") == "- [|]")
        #expect(typed("\t-a", into: "- x\n") == "- x\n\t- a|")
        #expect(typed("> -a") == "> - a|")
        // Typed as they are.
        #expect(typed("---") == "---|")
        #expect(typed("- a") == "- a|")
        #expect(typed("*a") == "*a|")
        // A bare marker under a paragraph line isn't a bullet.
        #expect(typed("-a", into: "Text\n") == "Text\n-a|")
    }

    @Test func aTableCellsListStartsAtItsTextEdge() throws {
        let h = GridHarness("| a |\n|---|\n| - x |\n")
        let storage = try #require(h.cell(1, 0).optionalTextStorage)
        let paragraph = try #require(storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let box = TaskCheckboxGeometry.size(for: baseFont, style: MarkdownEditorConfiguration.default.taskCheckbox)
        #expect(paragraph.firstLineHeadIndent == ceil((box - width("-")) / 2))
    }

    @Test func typingAttributesTakeTheHeadingsFont() {
        let tv = makeEditor("## Head\nBody")
        tv.setSelectedRange(NSRange(location: 7, length: 0))
        let headingSize = (tv.typingAttributes[.font] as? NSFont)?.pointSize ?? 0
        #expect(headingSize > size)
        tv.setSelectedRange(NSRange(location: 12, length: 0))
        #expect((tv.typingAttributes[.font] as? NSFont)?.pointSize == size)
    }
    #endif
}
