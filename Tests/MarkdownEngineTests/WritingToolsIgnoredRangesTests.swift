//
//  WritingToolsIgnoredRangesTests.swift
//  MarkdownEngineTests
//
//  Created by Luca Chen on 18.10.26.
//

// Fork: macOS only.
#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Writing Tools ignored ranges")
struct WritingToolsIgnoredRangesTests {
    private static let text = """
    Fix this sentence, run `brew install foo` and see $e=mc^2$.

    ```
    let x = 1
    ```

    Read [[Some Note]], the [docs](https://example.com) and ![chart](chart.png).
    """

    private func ignored(in range: NSRange? = nil, text: String = Self.text) -> [String] {
        let coordinator = NativeTextViewCoordinator(
            text: .constant(text), fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        // Fork: with tags read.
        var config = MarkdownEditorConfiguration.default
        config.tags = TagStyle(bubble: InlineBubble(fill: .blue, horizontalPadding: 6))
        coordinator.configuration = config
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        textView.string = text
        let ns = text as NSString
        guard #available(macOS 15.0, *) else { return [] }
        return coordinator.textView(textView, writingToolsIgnoredRangesInEnclosingRange: range ?? NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.rangeValue) }
    }

    @Test func codeFormulasAndLinksAreKeptAndProseIsNot() {
        let kept = ignored()
        #expect(kept == ["`brew install foo`", "$e=mc^2$", "```\nlet x = 1\n```", "[[Some Note]]",
                         "[docs](https://example.com)", "![chart](chart.png)"])
    }

    @Test func rangesAreClippedToTheEnclosingRange() {
        let ns = Self.text as NSString
        let start = ns.range(of: "install").location
        #expect(ignored(in: NSRange(location: start, length: 20)) == ["install foo`"])
    }

    // Fork: tags, task boxes and callout markers.

    @Test func tagsAreKept() {
        #expect(ignored(text: "Ask #work/team about it.") == ["#work/team"])
    }

    @Test func eachKindOfTaskBoxIsKeptAndItsTextIsNot() {
        let text = "- [ ] open item\n- [x] done item\n- [-] cancelled item\n1. [>] moved item\n"
        #expect(ignored(text: text) == ["[ ]", "[x]", "[-]", "[>]"])
    }

    @Test func aQuotedTaskBoxIsKept() {
        #expect(ignored(text: "> - [ ] quoted item\n") == ["[ ]"])
    }

    @Test func aCalloutsTypeAndFoldSignAreKeptAndItsTitleIsNot() {
        #expect(ignored(text: "> [!note] A title\n> Body text.\n") == ["[!note]"])
        #expect(ignored(text: "> [!warning]- Folded title\n> Body text.\n") == ["[!warning]-"])
        #expect(ignored(text: "> [!tip]\n> Body text.\n") == ["[!tip]"])
    }

    @Test func forkRangesAreClippedToTheEnclosingRange() {
        let text = "> [!note] A title\n- [x] done #work\n"
        let ns = text as NSString
        let start = ns.range(of: "note").location
        let end = NSMaxRange(ns.range(of: "[x"))
        #expect(ignored(in: NSRange(location: start, length: end - start), text: text) == ["note]", "[x"])
    }
}
#endif
