//
//  SpecConformanceTests.swift
//  MarkdownEngineSyntaxTests
//
//  Fork: every `spec/grammar` case through `MarkdownFacts`, and `spec/data` against the parser's tables.
//

import Foundation
import Testing
@testable import MarkdownEngineSyntax

enum Spec {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("spec")

    static func json(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func pretty(_ object: Any) -> String {
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\(object)"
    }

    static let grammarCases: [String] = {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("grammar").path)) ?? []
        return names.filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) }.sorted()
    }()
}

@Suite("Fork — Spec conformance")
struct SpecConformanceTests {

    @Test(arguments: Spec.grammarCases)
    func grammarCase(_ name: String) throws {
        let body = try String(contentsOf: Spec.root.appendingPathComponent("grammar/\(name).md"), encoding: .utf8)
        let expected = try Spec.json("grammar/\(name).facts.json")
        if let skip = expected["skip"] as? [String: String], let reason = skip["swift"] {
            #expect(!reason.isEmpty, "\(name): a skip needs a reason")
            return
        }
        let actual = Self.dictionary(MarkdownFacts.scan(body))
        for key in actual.keys.sorted() {
            let want = expected[key] ?? NSNull()
            let got = actual[key] ?? NSNull()
            #expect((want as AnyObject).isEqual(got),
                    "\(name).\(key)\nexpected \(Spec.pretty(want))\ngot \(Spec.pretty(got))")
        }
    }

    @Test func taskMarkersAreTheParsersMarkers() throws {
        let markers = try #require(try Spec.json("data/task-markers.json")["markers"] as? [[String: Any]])
        #expect(markers.compactMap { ($0["marker"] as? String)?.first } == TaskMarker.all)
    }

    @Test func taskMarkersAreTheBoxPatternsMarkers() throws {
        let markers = try #require(try Spec.json("data/task-markers.json")["markers"] as? [[String: Any]])
        let pattern = try NSRegularExpression(pattern: "^" + TaskMarker.boxPattern + "$")
        func matches(_ box: String) -> Bool { pattern.firstMatch(in: box, range: NSRange(location: 0, length: (box as NSString).length)) != nil }
        for marker in markers.compactMap({ $0["marker"] as? String }) { #expect(matches("[\(marker)]"), "[\(marker)]") }
        for other in ["y", "%", "a", "0"] { #expect(!matches("[\(other)]"), "[\(other)]") }
    }

    @Test func tagCharactersAreTheParsersCharacters() throws {
        let characters = try #require(try Spec.json("data/tags.json")["characters"] as? [String: Any])
        let other = try #require(characters["other"] as? [String])
        for c in other.compactMap(\.first) { #expect(TagSyntax.isTagCharacter(c), "\(c)") }
        if characters["letters"] as? Bool == true { for c in "aZé日" { #expect(TagSyntax.isTagCharacter(c)) } }
        if characters["digits"] as? Bool == true { for c in "019" { #expect(TagSyntax.isTagCharacter(c)) } }
        for c in " #.,!?[]()\t" { #expect(!TagSyntax.isTagCharacter(c)) }
    }

    @Test func everyGrammarCaseHasItsFacts() {
        #expect(Spec.grammarCases.count >= 21)
        for name in Spec.grammarCases {
            #expect(FileManager.default.fileExists(atPath: Spec.root.appendingPathComponent("grammar/\(name).facts.json").path),
                    "\(name).facts.json")
        }
    }

    // MARK: - Facts as the spec's JSON

    static func dictionary(_ facts: MarkdownFacts) -> [String: Any] {
        func optional(_ pairs: [(String, Any?)]) -> [String: Any] {
            var out: [String: Any] = [:]
            for (key, value) in pairs { if let value { out[key] = value } }
            return out
        }
        return [
            "summary": facts.summary ?? NSNull(),
            "headings": facts.headings.map { ["line": $0.line, "level": $0.level, "text": $0.text] },
            "tasks": facts.tasks.map { ["line": $0.line, "marker": String($0.marker), "text": $0.text] },
            "links": facts.links.map {
                optional([("line", $0.line), ("target", $0.parts.target), ("heading", $0.parts.heading),
                          ("block", $0.parts.block), ("alias", $0.parts.alias)])
            },
            "embeds": facts.embeds.map {
                optional([("line", $0.line), ("target", $0.target), ("heading", $0.heading), ("block", $0.block),
                          ("segments", $0.segments.isEmpty ? nil : $0.segments)])
            },
            "tags": facts.tags.map { ["line": $0.line, "tag": $0.name] },
            "callouts": facts.callouts.map {
                optional([("type", $0.type), ("fold", $0.fold.map { $0 == .open ? "open" : "folded" }),
                          ("title", $0.title), ("startLine", $0.startLine), ("endLine", $0.endLine)])
            },
            "tables": facts.tables.map { ["startLine": $0.startLine, "endLine": $0.endLine, "columns": $0.columns] },
        ]
    }
}
