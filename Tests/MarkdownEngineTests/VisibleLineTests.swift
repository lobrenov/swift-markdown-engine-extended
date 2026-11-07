//
//  VisibleLineTests.swift
//  MarkdownEngineTests
//
//  Fork: `onVisibleTopLine` and `SlashCommandProxy.scroll(toLine:)` (FORK.md #35).
//

import SwiftUI
import Testing
@testable import MarkdownEngine

#if os(macOS)
import AppKit

@MainActor
private final class ScrollRig {
    final class Box { var text = ""; var lines: [Int] = [] }
    let box = Box()
    let proxy = SlashCommandProxy()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
    var scrollView: NSScrollView!

    init(lines count: Int) async {
        _ = NSApplication.shared
        let box = box
        box.text = (0..<count).map { "Line \($0)" }.joined(separator: "\n") + "\n"
        let editor = NativeTextViewWrapper(
            text: Binding(get: { box.text }, set: { box.text = $0 }), documentId: "doc",
            slashCommandProxy: proxy, onVisibleTopLine: { box.lines.append($0) })
        let hosting = NSHostingView(rootView: editor)
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

    @Test func scrollingReportsTheTopLine() async throws {
        let rig = await ScrollRig(lines: 200)
        let lineHeight = try #require(rig.scrollView.documentView).bounds.height / 200
        await rig.scroll(to: lineHeight * 60)
        let reported = try #require(rig.box.lines.last)
        #expect(abs(reported - 60) <= 2, "reported \(reported)")
        await rig.scroll(to: 0)
        #expect(rig.box.lines.last == 0)
    }

    @Test func scrollToLinePutsTheLineAtTheTopAndReportsIt() async throws {
        let rig = await ScrollRig(lines: 200)
        rig.proxy.scroll(toLine: 120)
        await rig.settle()
        #expect(rig.box.lines.last == 120)
        rig.proxy.scroll(toLine: 5)
        await rig.settle()
        #expect(rig.box.lines.last == 5)
        rig.proxy.scroll(toLine: 0)
        await rig.settle()
        #expect(rig.box.lines.last == 0)
    }

    @Test func aLinePastTheEndClampsToTheEnd() async throws {
        let rig = await ScrollRig(lines: 200)
        rig.proxy.scroll(toLine: 10_000)
        await rig.settle()
        let reported = try #require(rig.box.lines.last)
        #expect(reported > 150 && reported <= 200)
    }

    @Test func eachChangeReportsOnce() async throws {
        let rig = await ScrollRig(lines: 200)
        rig.proxy.scroll(toLine: 50)
        await rig.settle()
        let count = rig.box.lines.count
        rig.proxy.scroll(toLine: 50)
        await rig.settle()
        #expect(rig.box.lines.count == count)
    }
}
#endif

#if os(iOS)
import UIKit

@MainActor
@Suite("Fork — visible top line", .serialized)
struct VisibleLineTests {

    private final class Box { var lines: [Int] = [] }

    private func harness(lines count: Int, _ box: Box) throws -> IOSEditorHarness {
        let text = (0..<count).map { "Line \($0)" }.joined(separator: "\n") + "\n"
        return try IOSEditorHarness(text, onVisibleTopLine: { box.lines.append($0) })
    }

    @Test func scrollingReportsTheTopLine() async throws {
        let box = Box()
        let harness = try harness(lines: 200, box)
        let textView = harness.textView
        harness.proxy.scroll(toLine: 100)
        await harness.settle()
        let lineHeight = textView.contentSize.height / 200
        box.lines = []
        textView.setContentOffset(CGPoint(x: 0, y: lineHeight * 60 - textView.adjustedContentInset.top), animated: false)
        await harness.settle()
        let reported = try #require(box.lines.last)
        #expect(abs(reported - 60) <= 8, "reported \(reported)")
    }

    @Test func scrollToLinePutsTheLineAtTheTopAndReportsIt() async throws {
        let box = Box()
        let harness = try harness(lines: 200, box)
        harness.proxy.scroll(toLine: 120)
        await harness.settle()
        #expect(box.lines.last == 120)
        harness.proxy.scroll(toLine: 0)
        await harness.settle()
        #expect(box.lines.last == 0)
    }

    @Test func aLinePastTheEndClampsToTheEnd() async throws {
        let box = Box()
        let harness = try harness(lines: 200, box)
        harness.proxy.scroll(toLine: 10_000)
        await harness.settle()
        let reported = try #require(box.lines.last)
        #expect(reported > 150 && reported <= 200)
    }
}
#endif
