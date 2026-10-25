//
//  ParserReadsTests.swift
//  MarkdownEngineSyntaxTests
//
//  Fork: the parsers read text as `NSString` matching does, character by
//  character where Foundation does (FORK.md #31).
//

import Foundation
import Testing
@testable import MarkdownEngineSyntax

@Suite("Fork — parser reads")
struct ParserReadsTests {
    @Test func aJoinerAfterAnHTMLCloserStillClosesTheBlock() {
        let blocks = BlockParser.parse("<!--x-->\u{200D}\nafter\n")
        #expect(blocks == [Block(kind: .html, range: NSRange(location: 0, length: 10)),
                           Block(kind: .paragraph, range: NSRange(location: 10, length: 6))])
    }

    @Test func aSummaryKeepsHTMLThatAPrependCharacterJoins() {
        #expect(MarkdownFacts.scan("\u{0600}<b>x").summary == "\u{0600}<b>x")
        #expect(MarkdownFacts.scan("\u{0600}&lt;").summary == "\u{0600}&lt;")
        #expect(MarkdownFacts.scan("<b>x</b> &lt;").summary == "x <")
    }

    @Test func theBufferReadsWhatTheStringHolds() {
        let ns = "a😀\u{301}\r\n" as NSString
        let buffer = UTF16Buffer(ns)
        #expect(buffer.length == ns.length)
        #expect((0..<ns.length).allSatisfy { buffer.character(at: $0) == ns.character(at: $0) })
        #expect(UTF16Buffer("" as NSString).length == 0)
    }
}
