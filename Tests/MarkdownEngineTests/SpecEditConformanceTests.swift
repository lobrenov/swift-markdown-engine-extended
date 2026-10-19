//
//  SpecEditConformanceTests.swift
//  MarkdownEngineTests
//
//  Fork: every `spec/edits` case through the editor (macOS) or `MarkdownTable`.
//

#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import MarkdownEngine
@testable import MarkdownEngineSyntax

private enum EditSpec {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("spec")

    struct Case: CustomTestStringConvertible, Sendable {
        let file: String
        let name: String
        let command: String
        let args: [String: String]
        let before: String
        let after: String
        let skip: String?
        var testDescription: String { "\(file): \(name)" }
    }

    static let cases: [Case] = {
        let dir = root.appendingPathComponent("edits")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        return files.flatMap { file -> [Case] in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(file)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cases = object["cases"] as? [[String: Any]] else { return [] }
            return cases.map { c in
                let args = (c["args"] as? [String: Any] ?? [:]).mapValues { "\($0)" }
                return Case(file: file, name: c["name"] as? String ?? "", command: c["command"] as? String ?? "",
                            args: args, before: c["before"] as? String ?? "", after: c["after"] as? String ?? "",
                            skip: (c["skip"] as? [String: String])?["swift"])
            }
        }
    }()

    /// The text without its `‸` or `«…»`, and the selection they mark (the end when there's none).
    static func unmark(_ marked: String) -> (text: String, selection: NSRange) {
        let ns = marked as NSString
        if ns.range(of: "‸").location != NSNotFound {
            let caret = ns.range(of: "‸").location
            return (ns.replacingCharacters(in: NSRange(location: caret, length: 1), with: ""), NSRange(location: caret, length: 0))
        }
        let open = ns.range(of: "«"), close = ns.range(of: "»")
        if open.location != NSNotFound, close.location != NSNotFound {
            let text = (marked.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: ""))
            return (text, NSRange(location: open.location, length: close.location - open.location - 1))
        }
        return (marked, NSRange(location: ns.length, length: 0))
    }

    static func mark(_ text: String, _ selection: NSRange) -> String {
        let ns = text as NSString
        guard selection.length > 0 else { return ns.replacingCharacters(in: selection, with: "‸") }
        let closed = ns.replacingCharacters(in: NSRange(location: NSMaxRange(selection), length: 0), with: "»") as NSString
        return closed.replacingCharacters(in: NSRange(location: selection.location, length: 0), with: "«")
    }

    /// The spec's toggle: an open marker becomes `x`, a done or cancelled one a space.
    static let toggles: [Character: Character] = {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("data/task-markers.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let markers = object["markers"] as? [[String: Any]] else { return [:] }
        var out: [Character: Character] = [:]
        for entry in markers {
            guard let marker = (entry["marker"] as? String)?.first else { continue }
            switch entry["state"] as? String {
            case "open": out[marker] = "x"
            case "done", "cancelled": out[marker] = " "
            default: break
            }
        }
        return out
    }()
}

@MainActor
@Suite("Fork — Spec edit conformance")
struct SpecEditConformanceTests {
    private static let calloutStyle = CalloutStyle(
        tint: { _ in .systemBlue }, drawIcon: { _, _, _ in }, titleColor: .labelColor, bodyColor: .textColor,
        foldColor: .gray, targetColor: .systemRed, fillOpacity: 0.09, ringOpacity: 0.24)

    @Test(arguments: EditSpec.cases)
    fileprivate func editCase(_ c: EditSpec.Case) throws {
        if let skip = c.skip {
            #expect(!skip.isEmpty, "a skip needs a reason")
            return
        }
        let (text, selection) = EditSpec.unmark(c.before)
        let expected = EditSpec.unmark(c.after)
        if c.command.hasPrefix("table.") {
            #expect(try tableEdit(c, text) == expected.text)
            return
        }
        let (tv, window, coordinator) = try editor(text)
        tv.setSelectedRange(selection)
        try apply(c, to: tv, text: text)
        let markedExpected = c.after.contains("‸") || c.after.contains("«") ? c.after : expected.text
        let got = markedExpected == expected.text ? tv.string : EditSpec.mark(tv.string, tv.selectedRange())
        #expect(got == markedExpected)
        withExtendedLifetime((window, coordinator)) {}
    }

    private func apply(_ c: EditSpec.Case, to tv: NativeTextView, text: String) throws {
        let ns = text as NSString
        func lineRange(_ key: String = "line") throws -> NSRange {
            let index = try #require(Int(c.args[key] ?? ""))
            var start = 0
            for _ in 0..<index { start = NSMaxRange(ns.lineRange(for: NSRange(location: start, length: 0))) }
            return ns.lineRange(for: NSRange(location: start, length: 0))
        }
        func box() throws -> NSRange {
            let line = try lineRange()
            let open = ns.range(of: "[", range: line)
            return NSRange(location: open.location, length: 3)
        }
        switch c.command {
        case "type":
            for character in c.args["text"] ?? "" { tv.insertText(String(character), replacementRange: tv.selectedRange()) }
        case "indent":
            tv.insertText("\t", replacementRange: tv.selectedRange())
        case "outdent":
            tv.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        case "task.toggle":
            let range = try box()
            tv.toggleTaskCheckbox((range, Character(ns.substring(with: NSRange(location: range.location + 1, length: 1))), .zero))
        case "task.set":
            tv.setTaskMarker(try #require(c.args["marker"]?.first), boxRange: try box())
        case "callout.setType":
            let line = try lineRange()
            let header = try #require(CalloutHeader.parse(ns, content: QuoteLine.parse(line, of: ns).content))
            tv.setSelectedRange(header.type)
            tv.insertText(try #require(c.args["type"]), replacementRange: header.type)
        default:
            Issue.record("Unknown command \(c.command)")
        }
    }

    private func tableEdit(_ c: EditSpec.Case, _ text: String) throws -> String {
        let ns = text as NSString
        let index = try #require(Int(c.args["line"] ?? ""))
        var start = 0
        for _ in 0..<index { start = NSMaxRange(ns.lineRange(for: NSRange(location: start, length: 0))) }
        var end = start
        while end < ns.length {
            let line = ns.lineRange(for: NSRange(location: end, length: 0))
            guard ns.substring(with: line).trimmingCharacters(in: .whitespaces).hasPrefix("|") else { break }
            end = NSMaxRange(line)
        }
        var source = ns.substring(with: NSRange(location: start, length: end - start))
        let newline = source.hasSuffix("\n")
        if newline { source.removeLast() }
        var table = try #require(MarkdownTable.parse(source))
        func int(_ key: String) throws -> Int { try #require(Int(c.args[key] ?? "")) }
        switch c.command {
        case "table.insertRow": table.insertRow(at: try int("row"))
        case "table.deleteRow": table.deleteRow(at: try int("row"))
        case "table.moveRow": table.moveRow(from: try int("from"), to: try int("to"))
        case "table.insertColumn": table.insertColumn(at: try int("column"))
        case "table.deleteColumn": table.deleteColumn(at: try int("column"))
        case "table.moveColumn": table.moveColumn(from: try int("from"), to: try int("to"))
        case "table.setCell": table.setCell(row: try int("row"), column: try int("column"), to: c.args["text"] ?? "")
        default: Issue.record("Unknown command \(c.command)")
        }
        return ns.replacingCharacters(in: NSRange(location: start, length: end - start), with: table.markdown + (newline ? "\n" : ""))
    }

    private func editor(_ text: String) throws -> (tv: NativeTextView, window: NSWindow, coordinator: NativeTextViewCoordinator) {
        _ = NSApplication.shared
        let coordinator = NativeTextViewCoordinator(
            text: .constant(text), fontName: "SF Pro", fontSize: 14,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        coordinator.configuration.callouts = Self.calloutStyle
        coordinator.configuration.lists.autoCloseFormattingEnabled = true
        coordinator.configuration.taskCheckbox.clickTransitions = EditSpec.toggles
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.configuration = coordinator.configuration
        tv.isEditable = true
        tv.allowsUndo = true
        tv.delegate = coordinator
        let scrollView = NSScrollView(frame: tv.frame)
        scrollView.documentView = tv
        let window = NSWindow(contentRect: tv.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scrollView
        let bridge = LayoutBridge(try #require(tv.textLayoutManager))
        coordinator.layoutBridge = bridge
        tv.layoutBridge = bridge
        coordinator.textView = tv
        coordinator.rebuildTextStorageAndStyle(tv, from: text)
        coordinator.lastSyncedText = text
        coordinator.lastComputedStorage = text
        coordinator.previousDisplayLength = (text as NSString).length
        return (tv, window, coordinator)
    }
}
#endif
