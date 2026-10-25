//
//  LinkPasteTests.swift
//  MarkdownEngineTests
//
//  Fork: a URL pasted over selected text makes a Markdown link.
//

import Testing
@testable import MarkdownEngine

@Suite("Fork — link paste")
struct LinkPasteTests {
    @Test func aURLOverSelectedTextMakesALink() {
        #expect(LinkPaste.link(pasting: "https://example.com/a?b=1", over: "the docs") == "[the docs](https://example.com/a?b=1)")
        #expect(LinkPaste.link(pasting: "  obsidian://open?vault=x\n", over: "vault") == "[vault](obsidian://open?vault=x)")
        #expect(LinkPaste.link(pasting: "mailto:a@example.com", over: "mail me") == "[mail me](mailto:a@example.com)")
    }

    @Test func otherPastesStayPlain() {
        #expect(LinkPaste.link(pasting: "https://example.com", over: "") == nil, "no selection")
        #expect(LinkPaste.link(pasting: "https://example.com", over: "two\nlines") == nil, "selection over a line end")
        #expect(LinkPaste.link(pasting: "plain words", over: "text") == nil)
        #expect(LinkPaste.link(pasting: "see https://example.com", over: "text") == nil, "text around the URL")
        #expect(LinkPaste.link(pasting: "https://a.com\nhttps://b.com", over: "text") == nil)
        #expect(LinkPaste.link(pasting: "note:thing", over: "text") == nil, "no ://")
    }
}
