//
//  ForkSyntaxTests.swift
//  MarkdownEngineSyntaxTests
//
//  Fork: wiki-link parts and the tag character rule.
//

import Foundation
import Testing
@testable import MarkdownEngineSyntax

@Suite("Fork — wiki-link parts")
struct WikiLinkPartsTests {
    @Test func targetHeadingBlockAndAlias() {
        #expect(WikiLinkParts(inner: "Title") == parts("Title"))
        #expect(WikiLinkParts(inner: "folder/Title|Shown") == parts("folder/Title", alias: "Shown"))
        #expect(WikiLinkParts(inner: "Title#Intro") == parts("Title", heading: "Intro"))
        #expect(WikiLinkParts(inner: "Title#^abc123|see") == parts("Title", block: "abc123", alias: "see"))
        #expect(WikiLinkParts(inner: " Title \t#Intro") == parts("Title", heading: "Intro"))
    }

    @Test func theBarSplitsBeforeTheHash() {
        #expect(WikiLinkParts(inner: "Title|alias #1") == parts("Title", alias: "alias #1"))
    }

    @Test func noTargetIsTheSameFile() {
        #expect(WikiLinkParts(inner: "#Intro") == parts("", heading: "Intro"))
        #expect(WikiLinkParts(inner: "#^b1|see") == parts("", block: "b1", alias: "see"))
    }

    @Test func noTargetHeadingOrBlockIsNoLink() {
        #expect(WikiLinkParts(inner: "#") == nil)
        #expect(WikiLinkParts(inner: "|alias") == nil)
        #expect(WikiLinkParts(inner: "  ") == nil)
    }

    private func parts(_ target: String, heading: String? = nil, block: String? = nil, alias: String? = nil) -> WikiLinkParts {
        var p = WikiLinkParts(inner: "x")!
        p.target = target
        p.heading = heading
        p.block = block
        p.alias = alias
        return p
    }
}

@Suite("Fork — tag characters")
struct TagSyntaxTests {
    @Test func lettersDigitsUnderscoreHyphenAndSlash() {
        #expect("aZ9_-/é日".allSatisfy(TagSyntax.isTagCharacter))
        #expect(!" #.,!?)]".contains(where: TagSyntax.isTagCharacter))
    }

    @Test func theInlineParserReadsTagsByTheSameRule() {
        let registry = ExtensionRegistry(syntax: [], tags: true)
        let nodes = InlineParser.parse("see #a-b/c_1 and #日本, not #12", registry: registry)
        let tags = nodes.compactMap { node -> NSRange? in if case .tag(let range, _) = node { range } else { nil } }
        let ns = "see #a-b/c_1 and #日本, not #12" as NSString
        #expect(tags.map { ns.substring(with: $0) } == ["#a-b/c_1", "#日本"])
    }
}

@Suite("Fork — autolinks")
struct AutolinkTests {
    private func autolinks(_ text: String) -> [NSRange] {
        InlineParser.parse(text).compactMap { node -> NSRange? in
            if case .link(let range, _, _, let markers, _) = node, markers.count == 2 { range } else { nil }
        }
    }

    @Test func anAngleBracketDestinationStaysTheLinks() {
        #expect(autolinks("[docs](<https://example.com>)").isEmpty)
        #expect(InlineParser.parse("[docs](<https://example.com>)").contains {
            if case .link(_, _, _, let markers, _) = $0 { markers.count == 4 } else { false }
        })
    }

    @Test func anEscapedBracketIsNoAutolink() {
        #expect(autolinks("\\<https://a.com>").isEmpty)
        #expect(autolinks("see <https://a.com> and <me@x.org>").count == 2)
    }
}

@Suite("Fork — fact ranges")
struct FactRangeTests {
    private func source(_ body: String, _ range: NSRange) -> String { (body as NSString).substring(with: range) }

    @Test func linksEmbedsAndBoxesKnowWhereTheyAre() {
        let body = "é [[A|b]] ![[c.png|300]]\n\n> - [/] 🙂 [[D#^x]]\n"
        let facts = MarkdownFacts.scan(body)
        #expect(facts.links.map { source(body, $0.range) } == ["[[A|b]]", "[[D#^x]]"])
        #expect(facts.embeds.map { source(body, $0.range) } == ["![[c.png|300]]"])
        #expect(facts.tasks.map { source(body, $0.box) } == ["[/]"])
    }

    @Test func aTableCellsLinksAreRangesInTheBody() {
        let body = "| A | B |\n| --- | --- |\n| x<br>[[T\\|al]] | ![[i.png\\|9]] [[U]] |\n"
        let facts = MarkdownFacts.scan(body)
        #expect(facts.links.map { source(body, $0.range) } == ["[[T\\|al]]", "[[U]]"])
        #expect(facts.links.map(\.parts.alias) == ["al", nil])
        #expect(facts.embeds.map { source(body, $0.range) } == ["![[i.png\\|9]]"])
    }

    @Test func aRowsFormFeedIsNoLineBreak() {
        let body = "| A |\n| - |\n| a\u{0C}b |\n| [[y]] |\n\npara\n"
        let facts = MarkdownFacts.scan(body)
        #expect(facts.links.map { source(body, $0.range) } == ["[[y]]"])
        #expect(facts.tables.map(\.endLine) == [3])
    }

    @Test func cellsTrimUnicodeSpaces() {
        let body = "| A | B |\n| - | - |\n\u{a0}| [[x]] |\u{a0}[[y]]\u{3000}|\n"
        #expect(MarkdownFacts.scan(body).links.map { source(body, $0.range) } == ["[[x]]", "[[y]]"])
    }

    @Test func aQuotedTablesLinksAreReadOnce() {
        let body = "> [!note]\n> | A |\n> | - |\n> | [[y\\|a]] [[z]] |\n>\n> [[after]]\n"
        let facts = MarkdownFacts.scan(body)
        #expect(facts.links.map { source(body, $0.range) } == ["[[y\\|a]]", "[[z]]", "[[after]]"])
        #expect(facts.links.map(\.parts.alias) == ["a", nil, nil])
        #expect(facts.tables.map(\.startLine) == [1])
    }
}

@Suite("Fork — Markdown link ranges")
struct MarkdownLinkRangeTests {
    private func source(_ body: String, _ range: NSRange) -> String { (body as NSString).substring(with: range) }

    @Test func aPathKnowsWhereItIs() {
        let body = "é [a](x%20y.md#h) ![b](<z w.png>) [c](u.md \"t\")\n\n> 🙂 [d](q.md?x=1)\n"
        let facts = MarkdownFacts.scan(body)
        #expect(facts.markdownLinks.map { source(body, $0.range) } == ["x%20y.md", "z w.png", "u.md", "q.md"])
        #expect(facts.markdownLinks.map(\.path) == ["x y.md", "z w.png", "u.md", "q.md"])
        #expect(facts.markdownLinks.map(\.angle) == [false, true, false, false])
        #expect(facts.markdownLinks.map(\.line) == [0, 0, 0, 2])
    }

    @Test func aTableCellsPathIsARangeInTheBody() {
        let body = "| A | B |\n| --- | --- |\n| x<br>[T](a\\|b.md) | ![i](c%20d.png) |\n"
        let facts = MarkdownFacts.scan(body)
        #expect(facts.markdownLinks.map { source(body, $0.range) } == ["a\\|b.md", "c%20d.png"])
        #expect(facts.markdownLinks.map(\.raw) == ["a\\|b.md", "c%20d.png"])
        #expect(facts.markdownLinks.map(\.path) == ["a|b.md", "c d.png"])
    }
}

@Suite("Fork — Markdown link forms")
struct MarkdownLinkFormTests {
    private func links(_ text: String) -> [(text: String, url: String)] {
        let ns = text as NSString
        func walk(_ nodes: [InlineNode]) -> [(text: String, url: String)] {
            nodes.flatMap { node -> [(text: String, url: String)] in
                switch node {
                case .link(_, let textRange, let url, let markers, let children) where markers.count == 4:
                    [(ns.substring(with: textRange), ns.substring(with: url))] + walk(children)
                case .image(_, let alt, let url, _):
                    [(ns.substring(with: alt), ns.substring(with: url))]
                default: []
                }
            }
        }
        return walk(InlineParser.parse(text)).map { ($0.text, $0.url) }
    }

    @Test func linkTextHoldsBracketsImagesAndNothingBetween() {
        #expect(links("[a [b] c](x.md)").map(\.url) == ["x.md"])
        #expect(links("[![a](b.png)](c.md)").map(\.url) == ["c.md", "b.png"])
        #expect(links("[](e.md) ![](p.png)").map(\.url) == ["e.md", "p.png"])
        #expect(links("[open [Real](real.md)").map(\.url) == ["real.md"])
        #expect(links("[outer [inner](i.md) outer](o.md)").map(\.url) == ["i.md"])
        #expect(links("[a] [b](c.md)").map(\.url) == ["c.md"])
    }

    @Test func aDestinationHoldsEscapesButNoBareSpace() {
        #expect(links("[a](x\\(1\\).md)").map(\.url) == ["x\\(1\\).md"])
        #expect(links("![a](dir/x\\.md)").map(\.url) == ["dir/x\\.md"])
        #expect(links("[a](My Note.md)").isEmpty)
        #expect(links("[a](<My Note.md>)").map(\.url) == ["<My Note.md>"])
        #expect(links("[a](x.md \"t\")[b](y.md 'u')[c](z.md (v))").count == 3)
        #expect(links("[a](x.md \"t\" extra)").isEmpty)
        #expect(links("[a](x.md\"t\")").map(\.url) == ["x.md\"t\""])
    }

    @Test func aLinkWrapsLines() {
        #expect(links("See [the old\nmap](Maps/Coast.md)").map(\.url) == ["Maps/Coast.md"])
        #expect(links("See [the old\r\nmap](m.md)").map(\.url) == ["m.md"])
        #expect(links("[a](b.md\n\"t\")").map(\.url) == ["b.md\n\"t\""])
        #expect(links("[a](\nb.md)").count == 1)
        #expect(links("> [a\n> b](q.md\n> \"t\")").count == 1)
        #expect(links("[a](b\nc.md)").isEmpty)
        #expect(links("[a](<b\nc.md>)").isEmpty)
    }

    @Test func editingTheSecondLineOfAWrappedLinkRetokenizes() {
        let state = DocumentParseState()
        var text = "A [wrapped\nlink](x.md) end\n\nNext"
        _ = state.tokens(for: text, edit: nil)
        for (range, insert) in [(NSRange(location: 17, length: 0), "y"), (NSRange(location: 18, length: 1), ""), (NSRange(location: 11, length: 0), " ")] {
            text = (text as NSString).replacingCharacters(in: range, with: insert)
            let edit = ParseEditDescriptor(editedRange: NSRange(location: range.location, length: (insert as NSString).length),
                                           delta: (insert as NSString).length - range.length)
            let incremental = state.tokens(for: text, edit: edit).map { "\($0.kind)|\($0.range)|\($0.contentRange)" }
            let full = MarkdownTokenizer.fullTokens(blocks: BlockParser.computeBlocks(text), ns: text as NSString)
                .map { "\($0.kind)|\($0.range)|\($0.contentRange)" }
            #expect(incremental == full)
            #expect(incremental.contains { $0.hasPrefix("link|") })
        }
    }
}
