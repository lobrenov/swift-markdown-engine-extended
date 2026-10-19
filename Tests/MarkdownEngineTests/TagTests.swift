//
//  TagTests.swift
//  MarkdownEngineTests
//
//  Fork: `#tags`, read as Obsidian reads them, drawn as
//  bubbles off the caret's line.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Fork — tags")
struct TagTests {

    private static let tagRegistry = ExtensionRegistry(extensions: [], tags: true)

    private func tags(_ text: String) -> [String] {
        let ns = text as NSString
        return InlineASTAdapter.tokens(from: InlineParser.parse(text, registry: Self.tagRegistry))
            .filter { $0.kind == .tag }
            .map { ns.substring(with: $0.range) }
    }

    @Test func tagsStartALineOrFollowWhitespace() {
        #expect(tags("#errands then #home/garden, #a-b_c.") == ["#errands", "#home/garden", "#a-b_c"])
        #expect(tags("issue#42 and #42 and #2026") == [])
        #expect(tags("#2026-goals #café") == ["#2026-goals", "#café"])
        #expect(tags("# heading-like and #") == [])
    }

    @Test func codeLinksEscapesAndURLsHoldNoTags() {
        #expect(tags("`#code` [[Note #Heading]] \\#escaped example.com/#top [see #label](x)") == [])
        #expect(tags("![[a #b]] #after") == ["#after"])
    }

    @Test func emphasisTakesTheBoundaryOfItsStart() {
        #expect(tags("*#lead* and **x #inner**") == ["#lead", "#inner"])
        #expect(tags("a*#no*") == [])
    }

    @Test func tagsAroundEmphasisSpacesAndSlashes() {
        #expect(tags("word _#urgent_ x") == ["#urgent"])
        #expect(tags("x __#a__ y") == ["#a"])
        #expect(tags("a *#b c") == [] && tags("a _#c d") == [])
        #expect(tags("日本\u{3000}#タグ") == ["#タグ"])
        #expect(tags("a\u{00A0}#nb") == ["#nb"])
        #expect(tags("x #a/ y") == ["#a"])
        let nodes = InlineParser.parse("word _#urgent_ x", registry: Self.tagRegistry)
        #expect(nodes.contains { if case .emphasis = $0 { true } else { false } })
    }

    @Test func tagsAreReadOnlyWhenTheRegistryAsksForThem() {
        let tokens = InlineASTAdapter.tokens(from: InlineParser.parse("a #tag", registry: .empty))
        #expect(!tokens.contains { $0.kind == .tag })
        #expect(ExtensionRegistry(extensions: [], tags: true).fingerprint != ExtensionRegistry.empty.fingerprint)
    }

    // MARK: - Styling

    private static let style = TagStyle(bubble: InlineBubble(fill: .blue, ring: .cyan, text: .systemBlue,
                                                             horizontalPadding: 6, margin: 1))

    private func attrs(_ text: String, caret: Int = -1) -> [StyledRange] {
        var config = MarkdownEditorConfiguration.default
        config.tags = Self.style
        return MarkdownASTStyler.styleAttributes(text: text, fontName: PlatformFont.systemFont(ofSize: 14).fontName,
                                                 fontSize: 14, caretLocation: caret, configuration: config)
    }

    private func kern(at location: Int, in attrs: [StyledRange]) -> CGFloat? {
        attrs.last { $0.range == NSRange(location: location, length: 1) && $0.attributes[.kern] != nil }?
            .attributes[.kern] as? CGFloat
    }

    @Test func aTagIsABubbleNamingItsTagWithTheHashFainter() {
        let styled = attrs("Ask #people/Marcus today\nnext")
        let tag = NSRange(location: 4, length: 14)
        #expect(styled.contains { $0.range == tag && $0.attributes[.markdownInlineBubble] is InlineBubbleSpan })
        #expect(styled.contains { $0.range == tag && $0.attributes[.markdownTag] as? String == "people/Marcus" })
        let hash = styled.last { $0.range == NSRange(location: 4, length: 1) && $0.attributes[.foregroundColor] != nil }
        #expect((hash?.attributes[.foregroundColor] as? PlatformColor)?.alphaComponent == 0.65)
        // The space before and the last character make room for the padding outside the text.
        #expect(kern(at: 3, in: styled) == 7 && kern(at: 17, in: styled) == 7)
    }

    @Test func onTheCaretsLineATagIsPlainSource() {
        let text = "Ask #errands today\nnext"
        #expect(!attrs(text, caret: 0).contains { $0.attributes[.markdownInlineBubble] != nil })
        #expect(!attrs(text, caret: 18).contains { $0.attributes[.markdownTag] != nil })
        #expect(attrs(text, caret: 20).contains { $0.attributes[.markdownTag] != nil })
    }

    @Test func aTagsTokenIsActiveAnywhereOnItsLine() {
        let text = "Ask #errands today\nnext" as NSString
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text as String, registry: Self.tagRegistry)
        let index = try! #require(tokens.firstIndex { $0.kind == .tag })
        func active(_ caret: Int) -> Bool {
            MarkdownDetection.computeActiveTokenIndices(selectionRange: NSRange(location: caret, length: 0),
                                                        tokens: tokens, in: text).contains(index)
        }
        #expect(active(0) && active(18))
        #expect(!active(19) && !active(22))
    }
}
