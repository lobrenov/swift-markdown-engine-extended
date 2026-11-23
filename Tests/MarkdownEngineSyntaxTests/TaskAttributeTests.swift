//
//  TaskAttributeTests.swift
//  MarkdownEngineSyntaxTests
//
//  Fork: a task line's `>YYYY-MM-DD` and `@[[Title]]`, read only when the registry asks and only on task lines.
//

import Foundation
import Testing
@testable import MarkdownEngineSyntax

@Suite("Fork — task attributes")
struct TaskAttributeTests {

    private static let on = ExtensionRegistry(syntax: [], taskAttributes: true)

    /// Each attribute in the document's list items, as `kind:source`.
    private func attributes(_ text: String, registry: ExtensionRegistry = TaskAttributeTests.on) -> [String] {
        let ns = text as NSString
        var found: [String] = []
        for block in DocumentAST.parse(text, registry: registry) {
            guard case .list(_, let items) = block else { continue }
            for item in items {
                for case .taskAttribute(let kind, let range, _, _, _) in item.inlines {
                    found.append("\(kind == .due ? "due" : "parent"):\(ns.substring(with: range))")
                }
            }
        }
        return found
    }

    @Test func aTaskLineHoldsADueDateAndAParent() {
        #expect(attributes("- [ ] call >2026-10-02 now") == ["due:>2026-10-02"])
        #expect(attributes("- [x] move @[[Ta Da MVP]] now") == ["parent:@[[Ta Da MVP]]"])
        #expect(attributes("1. [/] a >2026-10-02 @[[Home|Casa]]") == ["due:>2026-10-02", "parent:@[[Home|Casa]]"])
        #expect(attributes("- [ ] >2026-10-02") == ["due:>2026-10-02"])
        #expect(attributes("  - [ ] nested @[[A]]") == ["parent:@[[A]]"])
    }

    @Test func everyValidAttributeIsANode() {
        #expect(attributes("- [ ] >2026-10-02 >2026-10-03 @[[A]] @[[B]]")
                == ["due:>2026-10-02", "due:>2026-10-03", "parent:@[[A]]", "parent:@[[B]]"])
    }

    @Test func otherLinesHoldNone() {
        #expect(attributes("- plain >2026-10-02 @[[A]]").isEmpty)
        #expect(attributes("1. item >2026-10-02").isEmpty)
        #expect(DocumentAST.parse("Prose >2026-10-02 @[[A]]", registry: Self.on).allSatisfy {
            if case .paragraph(_, let inlines) = $0 { return !inlines.contains { if case .taskAttribute = $0 { true } else { false } } }
            return true
        })
    }

    @Test func aQuoteMarkerAtALineStartStaysAQuote() {
        let blocks = DocumentAST.parse(">2026-10-02 quoted", registry: Self.on)
        #expect(blocks.contains { if case .blockquote = $0 { true } else { false } })
        #expect(attributes("- [ ] a\n>2026-10-02 b").isEmpty)
        #expect(attributes("> - [ ] a >2026-10-02").isEmpty)
    }

    @Test func codeLinksEscapesAndEmphasisHoldNone() {
        #expect(attributes("- [ ] `>2026-10-02` `@[[A]]`").isEmpty)
        #expect(attributes("- [ ] \\>2026-10-02 \\@[[A]]").isEmpty)
        #expect(attributes("- [ ] [x >2026-10-02](y.md) **a >2026-10-02**").isEmpty)
        #expect(attributes("```\n- [ ] >2026-10-02\n```").isEmpty)
    }

    @Test func aDateNeedsWhitespaceBeforeAndABoundaryAfter() {
        #expect(attributes("- [ ] a>2026-10-02 (>2026-10-02) ->2026-10-02").isEmpty)
        #expect(attributes("- [ ] >2026-10-02x >2026-10-021 >2026-10-02-1 >2026-10-02_").isEmpty)
        #expect(attributes("- [ ] >2026-10-02, >2026-10-03. >2026-10-04) >2026-10-05**b**")
                == ["due:>2026-10-02", "due:>2026-10-03", "due:>2026-10-04", "due:>2026-10-05"])
    }

    @Test func aDateIsARealDate() {
        #expect(attributes("- [ ] >2026-02-29 >2026-13-01 >2026-00-10 >2026-04-31 >2026-1-02 >26-10-02 >2026/10/02").isEmpty)
        #expect(attributes("- [ ] >2028-02-29 >2026-12-31 >2000-02-29") == ["due:>2028-02-29", "due:>2026-12-31", "due:>2000-02-29"])
        #expect(!TaskAttributeSyntax.isDate("1900-02-29") && TaskAttributeSyntax.isDate("2026-01-01"))
    }

    @Test func aParentIsAWikiLinkRightAfterAt() {
        #expect(attributes("- [ ] @ [[A]] x@[[A]] [[A]] @[A] @[[A").isEmpty)
        #expect(attributes("- [ ] ![[a.png]] @[[A#Part]] @[[]]") == ["parent:@[[A#Part]]"])
    }

    @Test func theTextAroundAnAttributeStays() {
        let text = "- [ ] a >2026-10-02 b @[[T]] c"
        let ns = text as NSString
        let blocks = DocumentAST.parse(text, registry: Self.on)
        guard case .list(_, let items) = blocks[0] else { Issue.record("not a list"); return }
        let covered = items[0].inlines.map { node -> String in
            switch node {
            case .text(let range): "text:" + ns.substring(with: range)
            case .taskAttribute(let kind, let range, let marker, let content, let markers):
                "\(kind):" + ns.substring(with: range) + "|" + ns.substring(with: marker) + "|" + ns.substring(with: content)
                    + "|\(markers.count)"
            default: "other"
            }
        }
        #expect(covered == ["text:a ", "due:>2026-10-02|>|2026-10-02|1", "text: b ", "parent:@[[T]]|@|T|3", "text: c"])
    }

    @Test func attributesAreReadOnlyWhenTheRegistryAsksForThem() {
        #expect(attributes("- [ ] a >2026-10-02 @[[A]]", registry: .empty).isEmpty)
        #expect(Self.on.fingerprint != ExtensionRegistry.empty.fingerprint)
        #expect(Self.on.fingerprint != ExtensionRegistry(syntax: [], tags: true).fingerprint)
    }

    @Test func attributesDoNotChangeTheLinksAndTagsAroundThem() {
        let facts = MarkdownFacts.scan("- [ ] #home >2026-10-02 @[[Ta Da]] [[Other]]\n")
        #expect(facts.links.map(\.parts.target) == ["Ta Da", "Other"])
        #expect(facts.tags.map(\.name) == ["home"])
        #expect(facts.tasks[0].text == "#home >2026-10-02 @[[Ta Da]] [[Other]]")
    }

    @Test func factsPlaceEachAttributeInItsLine() {
        let facts = MarkdownFacts.scan("Intro\n\n- [ ] é >2026-10-02 @[[Home|Casa]]\n- [x] none\n")
        let task = facts.tasks[0]
        #expect(task.line == 2)
        #expect(task.attributes == [
            .init(kind: .due, column: 8, length: 11, value: "2026-10-02"),
            .init(kind: .parent, column: 20, length: 14, value: "Home|Casa"),
        ])
        #expect(facts.tasks[1].attributes.isEmpty)
    }
}
