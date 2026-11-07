//
//  VisibleLineTests.swift
//  MarkdownEngineTests
//
//  Fork: `onVisibleLines` and `SlashCommandProxy.scroll(toLine:)` (FORK.md #35).
//

import SwiftUI
import Testing
@testable import MarkdownEngine
@testable import MarkdownEngineSyntax

private func numbered(_ count: Int, prefix: String = "Line") -> String {
    (0..<count).map { "\(prefix) \($0)" }.joined(separator: "\n") + "\n"
}

/// Text with every kind of line terminator before a heading.
private let mixedTerminators: String = {
    let filler = (0..<60).map { "f\($0)" }
    return filler.joined(separator: "\r\n") + "\r\nx\u{2028}y\u{2029}z\u{85}w\rv\n## Target\n\n"
        + (0..<80).map { "after \($0)" }.joined(separator: "\n") + "\n"
}()

#if os(macOS)
import AppKit
import Observation

@Observable
@MainActor
private final class Model {
    var documentId = "a"
    var text: String
    var lines: [ClosedRange<Int>] = []
    init(text: String) { self.text = text }
}

private struct Root: View {
    let model: Model
    let proxy: SlashCommandProxy
    let fits: Bool

    var body: some View {
        var configuration = MarkdownEditorConfiguration.default
        configuration.heightBehavior = fits ? .fitsContent : .scrolls
        let editor = NativeTextViewWrapper(
            text: Binding(get: { model.text }, set: { model.text = $0 }), configuration: configuration,
            documentId: model.documentId, slashCommandProxy: proxy, onVisibleLines: { model.lines.append($0) })
        return fits ? AnyView(ScrollView { editor }) : AnyView(editor)
    }
}

@MainActor
private final class ScrollRig {
    let model: Model
    let proxy = SlashCommandProxy()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
    var scrollView: NSScrollView!
    var lines: [ClosedRange<Int>] { model.lines }

    init(text: String, fits: Bool = false) async {
        _ = NSApplication.shared
        model = Model(text: text)
        let hosting = NSHostingView(rootView: Root(model: model, proxy: proxy, fits: fits))
        hosting.frame = window.contentRect(forFrameRect: window.frame)
        window.contentView = hosting
        window.orderBack(nil)
        func find(_ view: NSView) -> NSScrollView? {
            if let found = view as? NSScrollView { return found }
            for subview in view.subviews { if let found = find(subview) { return found } }
            return nil
        }
        await settle()
        scrollView = find(hosting)
    }

    func settle() async {
        for _ in 0..<4 {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    func scroll(to y: CGFloat) async {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        await settle()
    }
}

@MainActor
@Suite("Fork — visible top line", .serialized)
struct VisibleLineTests {

    @Test(arguments: [false, true]) func scrollingReportsTheTopLine(fits: Bool) async throws {
        let rig = await ScrollRig(text: numbered(200), fits: fits)
        let lineHeight = try #require(rig.scrollView.documentView).bounds.height / 200
        await rig.scroll(to: lineHeight * 60)
        let reported = try #require(rig.lines.last?.lowerBound)
        #expect(abs(reported - 60) <= 3, "reported \(reported)")
        await rig.scroll(to: 0)
        #expect(rig.lines.last?.lowerBound == 0)
    }

    @Test(arguments: [false, true]) func scrollToLinePutsTheLineAtTheTopAndReportsIt(fits: Bool) async throws {
        let rig = await ScrollRig(text: numbered(200), fits: fits)
        rig.proxy.scroll(toLine: 120)
        await rig.settle()
        #expect(rig.lines.last?.lowerBound == 120)
        let visible = try #require(rig.lines.last)
        #expect(visible.count > 3 && visible.count < 40, "\(visible)")
        rig.proxy.scroll(toLine: 5)
        await rig.settle()
        #expect(rig.lines.last?.lowerBound == 5)
        rig.proxy.scroll(toLine: 0)
        await rig.settle()
        #expect(rig.lines.last?.lowerBound == 0)
    }

    @Test(arguments: [false, true]) func aLinePastTheEndClampsToTheEnd(fits: Bool) async throws {
        let rig = await ScrollRig(text: numbered(200), fits: fits)
        rig.proxy.scroll(toLine: 10_000)
        await rig.settle()
        let reported = try #require(rig.lines.last?.lowerBound)
        #expect(reported > 150 && reported <= 200)
        #expect(rig.lines.last?.upperBound == 199)
    }

    @Test(arguments: [false, true]) func theLastLineFollowsTheViewport(fits: Bool) async throws {
        let rig = await ScrollRig(text: numbered(200), fits: fits)
        let top = try #require(rig.lines.last)
        #expect(top.lowerBound == 0 && top.upperBound >= 5 && top.upperBound < 40, "top \(top)")
        rig.proxy.scroll(toLine: 100)
        await rig.settle()
        let middle = try #require(rig.lines.last)
        #expect(middle.lowerBound == 100 && middle.upperBound >= 105 && middle.upperBound < 140, "middle \(middle)")
        #expect(middle.count == top.count || abs(middle.count - top.count) <= 2)
    }

    @Test func eachChangeReportsOnce() async throws {
        let rig = await ScrollRig(text: numbered(200))
        rig.proxy.scroll(toLine: 50)
        await rig.settle()
        let count = rig.lines.count
        rig.proxy.scroll(toLine: 50)
        await rig.settle()
        #expect(rig.lines.count == count)
    }

    @Test(arguments: [false, true]) func linesFollowTheParsersLineTerminators(fits: Bool) async throws {
        let rig = await ScrollRig(text: mixedTerminators, fits: fits)
        let coordinator = try #require(rig.proxy.coordinator)
        let text = try #require(rig.proxy.textView).string
        let heading = try #require(MarkdownFacts.scan(text).headings.first)
        #expect(coordinator.lineIndex(at: (text as NSString).range(of: "## Target").location, in: text as NSString) == heading.line)
        rig.proxy.scroll(toLine: heading.line)
        await rig.settle()
        #expect(rig.lines.last?.lowerBound == heading.line)
    }

    @Test(arguments: [false, true]) func switchingDocumentsReports(fits: Bool) async throws {
        let rig = await ScrollRig(text: numbered(200), fits: fits)
        rig.proxy.scroll(toLine: 100)
        await rig.settle()
        #expect(rig.lines.last?.lowerBound == 100)
        let count = rig.lines.count
        rig.model.text = numbered(200, prefix: "Other")
        rig.model.documentId = "b"
        await rig.settle()
        #expect(rig.lines.count > count)
        let switched = try #require(rig.lines.last)
        // The page keeps its scroll position in `.fitsContent`; the editor's own scroll view opens at the top.
        #expect(fits || switched.lowerBound == 0)
        #expect(switched.count >= 5 && switched.count < 40, "after the switch \(switched)")
    }

    @Test(arguments: [false, true]) func switchingToALongerDocumentReportsItsViewport(fits: Bool) async throws {
        let rig = await ScrollRig(text: "short\n", fits: fits)
        rig.model.text = numbered(300, prefix: "Longer")
        rig.model.documentId = "b"
        await rig.settle()
        let last = try #require(rig.lines.last)
        #expect(last.lowerBound == 0 && last.upperBound >= 5 && last.upperBound < 40, "\(last)")
    }

    @Test(arguments: [false, true]) func editingTheTextReportsTheViewportAgain(fits: Bool) async throws {
        let rig = await ScrollRig(text: "short\n", fits: fits)
        rig.model.text = numbered(300, prefix: "Longer")
        await rig.settle()
        let last = try #require(rig.lines.last)
        #expect(last.lowerBound == 0 && last.upperBound >= 5 && last.upperBound < 40, "\(last)")
    }
}
#endif

#if os(iOS)
import UIKit

@MainActor
@Suite("Fork — visible top line", .serialized)
struct VisibleLineTests {

    private final class Box { var lines: [ClosedRange<Int>] = [] }

    private func harness(_ text: String, fits: Bool, _ box: Box) throws -> IOSEditorHarness {
        let harness = try IOSEditorHarness(text, configure: { if fits { $0.heightBehavior = .fitsContent } },
                                           onVisibleLines: { box.lines.append($0) })
        // UIKit scrolls an ancestor to a focused editor's caret.
        harness.textView.resignFirstResponder()
        harness.textView.selectedRange = NSRange(location: 0, length: 0)
        return harness
    }

    @Test(arguments: [false, true]) func scrollingReportsTheTopLine(fits: Bool) async throws {
        let box = Box()
        let harness = try harness(numbered(200), fits: fits, box)
        harness.proxy.scroll(toLine: 100)
        await harness.settle()
        let scroller = try #require(fits ? harness.scrollView : harness.textView)
        let lineHeight = harness.textView.contentSize.height / 200
        box.lines = []
        scroller.setContentOffset(CGPoint(x: 0, y: lineHeight * 60 - scroller.adjustedContentInset.top), animated: false)
        await harness.settle()
        let reported = try #require(box.lines.last?.lowerBound)
        #expect(abs(reported - 60) <= 8, "reported \(reported)")
    }

    @Test(arguments: [false, true]) func scrollToLinePutsTheLineAtTheTopAndReportsIt(fits: Bool) async throws {
        let box = Box()
        let harness = try harness(numbered(200), fits: fits, box)
        harness.proxy.scroll(toLine: 120)
        await harness.settle()
        #expect(box.lines.last?.lowerBound == 120)
        let visible = try #require(box.lines.last)
        #expect(visible.count > 3 && visible.count < 40, "\(visible)")
        harness.proxy.scroll(toLine: 0)
        await harness.settle()
        #expect(box.lines.last?.lowerBound == 0)
    }

    @Test(arguments: [false, true]) func aLinePastTheEndClampsToTheEnd(fits: Bool) async throws {
        let box = Box()
        let harness = try harness(numbered(200), fits: fits, box)
        harness.proxy.scroll(toLine: 10_000)
        await harness.settle()
        let reported = try #require(box.lines.last?.lowerBound)
        #expect(reported > 150 && reported <= 200)
        #expect(box.lines.last?.upperBound == 199)
    }

    @Test(arguments: [false, true]) func theLastLineFollowsTheViewport(fits: Bool) async throws {
        let box = Box()
        let harness = try harness(numbered(200), fits: fits, box)
        await harness.settle()
        let top = try #require(box.lines.last)
        #expect(top.lowerBound == 0 && top.upperBound >= 5 && top.upperBound < 40, "top \(top)")
        harness.proxy.scroll(toLine: 100)
        await harness.settle()
        let middle = try #require(box.lines.last)
        #expect(middle.lowerBound == 100 && middle.upperBound >= 105 && middle.upperBound < 140, "middle \(middle)")
    }

    @Test(arguments: [false, true]) func linesFollowTheParsersLineTerminators(fits: Bool) async throws {
        let box = Box()
        let harness = try harness(mixedTerminators, fits: fits, box)
        let coordinator = try #require(harness.proxy.coordinator)
        let text = harness.textView.string
        let heading = try #require(MarkdownFacts.scan(text).headings.first)
        #expect(coordinator.lineIndex(at: (text as NSString).range(of: "## Target").location, in: text as NSString) == heading.line)
        harness.proxy.scroll(toLine: heading.line)
        await harness.settle()
        #expect(box.lines.last?.lowerBound == heading.line)
    }
}
#endif

#if os(macOS)
@MainActor
@Suite("Fork — visible lines in a long document")
struct LongVisibleLineTests {
    @Test func aLongDocumentReportsTheViewport() async throws {
        let rig = await ScrollRig(text: numbered(6000, prefix: "Some longer line of text that holds more words, line"), fits: true)
        let top = try #require(rig.lines.last)
        #expect(top.lowerBound == 0 && top.upperBound < 40, "top \(top)")
    }
}
#endif
