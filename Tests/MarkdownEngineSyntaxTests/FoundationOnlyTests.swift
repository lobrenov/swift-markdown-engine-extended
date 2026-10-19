//
//  FoundationOnlyTests.swift
//  MarkdownEngineSyntaxTests
//
//  Fork: `MarkdownEngineSyntax` imports Foundation only.
//

import Foundation
import Testing

struct FoundationOnlyTests {
    @Test func theSyntaxTargetImportsNoUIFramework() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MarkdownEngineSyntax")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let imports = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n")
                .filter { $0.hasPrefix("import ") || $0.hasPrefix("@testable import ") }
            for line in imports {
                #expect(!["AppKit", "UIKit", "SwiftUI"].contains { line.hasSuffix(" \($0)") },
                        "\(file.lastPathComponent): \(line)")
            }
        }
    }
}
