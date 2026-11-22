//
//  TagEditTests.swift
//  MarkdownEngineSyntaxTests
//
//  Fork: `spec/edits/tags.json` through `TagEdit`, and the tag positions the edits read.
//

import Foundation
import Testing
@testable import MarkdownEngineSyntax

private struct TagEditCase: CustomTestStringConvertible, Sendable {
    let name: String
    let command: String
    let from: String
    let to: String
    let before: String
    let after: String
    var testDescription: String { name }

    static let all: [TagEditCase] = {
        guard let object = try? Spec.json("edits/tags.json"), let cases = object["cases"] as? [[String: Any]] else { return [] }
        return cases.map { c in
            let args = c["args"] as? [String: String] ?? [:]
            return TagEditCase(name: c["name"] as? String ?? "", command: c["command"] as? String ?? "",
                               from: args["from"] ?? "", to: args["to"] ?? "",
                               before: c["before"] as? String ?? "", after: c["after"] as? String ?? "")
        }
    }()
}

@Suite("Fork — Tag edits")
struct TagEditTests {
    @Test func theSpecHasCases() {
        #expect(TagEditCase.all.count >= 30)
    }

    @Test(arguments: TagEditCase.all)
    fileprivate func editCase(_ c: TagEditCase) {
        switch c.command {
        case "tag.rename": #expect(TagEdit.rename(c.from, to: c.to, in: c.before) == c.after)
        case "tag.delete": #expect(TagEdit.delete(c.from, in: c.before) == c.after)
        default: Issue.record("Unknown command \(c.command)")
        }
    }

    @Test func aTagIsPositionedInUTF16UnitsOfItsLine() {
        let facts = MarkdownFacts.scan("😀 #a/b/ x\r\n日本 #タグ\n")
        #expect(facts.tags.map(\.line) == [0, 1])
        #expect(facts.tags.map(\.column) == [3, 3])
        #expect(facts.tags.map(\.length) == [4, 3])
    }

    @Test func editsKeepTextAroundSurrogatePairs() {
        #expect(TagEdit.rename("a", to: "bb", in: "😀 #a 😀") == "😀 #bb 😀")
        #expect(TagEdit.delete("a", in: "😀 #a 😀") == "😀 😀")
    }
}
