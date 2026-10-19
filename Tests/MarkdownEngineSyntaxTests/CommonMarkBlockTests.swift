//
//  CommonMarkBlockTests.swift
//  MarkdownEngineSyntaxTests
//
//  Fork: the CommonMark block forms (FORK.md #27): what they read as, and edits whose spliced parse must
//  equal the full parse.
//

import Foundation
import Testing
@testable import MarkdownEngineSyntax

@Suite("Fork — CommonMark blocks")
struct CommonMarkBlockTests {

    private func kinds(_ text: String) -> [BlockKind] {
        BlockParser.computeBlocks(text).map(\.kind)
    }

    /// Applies the edit and checks the splice (when it doesn't fall back) against a full parse.
    private func expectSpliceMatches(_ before: String, at location: Int, delete: Int = 0, insert: String,
                                     sourceLocation: SourceLocation = #_sourceLocation) {
        let old = Array(before.utf16)
        let after = (before as NSString).replacingCharacters(in: NSRange(location: location, length: delete), with: insert)
        let new = Array(after.utf16)
        let diff = BufferDiff(changeStart: location, changeEndOld: location + delete,
                              changeEndNew: location + (insert as NSString).length, delta: new.count - old.count)
        let full = BlockParser.computeBlocks(after)
        if let spliced = BlockParser.incrementalParse(oldChars: old, oldBlocks: BlockParser.computeBlocks(before),
                                                      newChars: new, newNS: after as NSString, diff: diff) {
            #expect(spliced.blocks == full, "\(before.debugDescription) → \(after.debugDescription)", sourceLocation: sourceLocation)
        }
    }

    @Test func indentedLinesAfterAListOrInAParagraphAreNotCode() {
        #expect(kinds("Notes\n    - indented item\n") == [.paragraph])
        #expect(kinds("- a\n  more\n    - sub\n") == [.list, .paragraph])
        #expect(kinds("- a\n\n    b\n") == [.list, .blank, .paragraph])
        #expect(kinds("Text\n\n    code\n") == [.paragraph, .blank, .indentedCode])
    }

    @Test func listContextReachesPastTheWindow() {
        expectSpliceMatches("- a\n\n    b\n\n# H\n", at: 10, insert: "c")
        expectSpliceMatches("- a\n\n    - b\n", at: 12, insert: "c")
        expectSpliceMatches("- a\n\n\t- b\n", at: 9, insert: "c")
        expectSpliceMatches("# H\n\nfoo\n\n    bar\n\n# Z\n", at: 5, insert: "- ")
        expectSpliceMatches("# H\n\n- foo\n\n    bar\n\n# Z\n", at: 5, delete: 2, insert: "")
    }

    @Test func htmlBlocksAndIndentedCodeRunPastTheWindow() {
        expectSpliceMatches("<div>\nfoo\n\npara\n- item\n\n# H\n", at: 10, insert: "x")
        expectSpliceMatches("<!DOCTYPE x\nfoo >\n\npara\n\n# H\n", at: 16, delete: 1, insert: "")
        expectSpliceMatches("# H\n\n   foo\n\n    code2\n", at: 5, insert: " ")
    }

    @Test func proseWithAngleBracketsSplices() {
        let text = "# H\n\nA -> B and x < y\n\nEnd\n"
        let old = Array(text.utf16)
        #expect(!BlockParser.hasBlockDelimiter(old, 10, 10))
        #expect(BlockParser.hasBlockDelimiter(Array("<div>\n".utf16), 2, 2))
        #expect(BlockParser.hasBlockDelimiter(Array("a -->\n".utf16), 4, 4))
    }
}
