//
//  TextInsetsTests.swift
//  MarkdownEngineTests
//
//  Fork: separate leading and trailing text insets. The text starts at the leading margin and wraps at the
//  trailing one; gutter labels, the placeholder and margin clicks follow the leading margin.
//

#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Fork — leading and trailing text insets", .serialized)
struct TextInsetsTests {
    static let leading: CGFloat = 120
    static let trailing: CGFloat = 40
    static let width: CGFloat = 900
    static let text = "Intro paragraph that is long enough to wrap across several lines when the column is narrow, "
        + "so the wrap width can be measured from the right margin of the editor view.\n\n"
        + "* 30 min: Serve.\n"

    private func host(_ config: MarkdownEditorConfiguration) throws
        -> (NativeTextView, NSWindow) {
        _ = NSApplication.shared
        let editor = NativeTextViewWrapper(text: .constant(Self.text), configuration: config, documentId: "doc")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: editor)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        func find(_ view: NSView) -> NativeTextView? {
            if let tv = view as? NativeTextView { return tv }
            return view.subviews.lazy.compactMap(find).first
        }
        let tv = try #require(find(window.contentView!))
        tv.textLayoutManager?.ensureLayout(for: tv.textLayoutManager!.documentRange)
        return (tv, window)
    }

    private func config() -> MarkdownEditorConfiguration {
        var config = MarkdownEditorConfiguration.default
        config.textInsets = TextInsets(leading: Self.leading, trailing: Self.trailing, vertical: 10)
        config.lists.gutterPrefix = ListGutterTests.steps
        return config
    }

    @Test("horizontal still sets both margins and reads their mean")
    func horizontalCompatibility() {
        var insets = TextInsets(horizontal: 30, vertical: 5)
        #expect(insets.leading == 30 && insets.trailing == 30 && insets.horizontal == 30)
        insets.horizontal = 12
        #expect(insets.leading == 12 && insets.trailing == 12)
        #expect(TextInsets(leading: 100, trailing: 20).horizontal == 60)
    }

    @Test("the text starts at the leading margin and wraps at the trailing one")
    func startsAtLeadingWrapsAtTrailing() throws {
        let (tv, window) = try host(config())
        defer { window.contentView = nil }
        #expect(abs(tv.textContainerOrigin.x - Self.leading) < 0.5)
        let container = try #require(tv.textContainer)
        #expect(abs(container.size.width - (tv.bounds.width - Self.leading - Self.trailing)) < 0.5)

        let bridge = try #require(tv.layoutBridge)
        let first = bridge.boundingRect(forCharacterRange: NSRange(location: 0, length: 1), in: container)
        #expect(abs(first.minX + tv.textContainerOrigin.x - Self.leading) < 0.5)
        let wrapped = bridge.boundingRect(forCharacterRange: NSRange(location: 0, length: 150), in: container)
        let right = wrapped.maxX + tv.textContainerOrigin.x
        #expect(right <= tv.bounds.width - Self.trailing + 0.5)
        #expect(right > tv.bounds.width - Self.trailing - 120)
    }

    @Test("a gutter label's surface reaches the view's left edge")
    func gutterSurfaceReachesLeftEdge() throws {
        let (tv, window) = try host(config())
        defer { window.contentView = nil }
        let tlm = try #require(tv.textLayoutManager)
        let location = (Self.text as NSString).range(of: "* 30").location
        let position = try #require(tlm.location(tlm.documentRange.location, offsetBy: location))
        let fragment = try #require(tlm.textLayoutFragment(for: position))
        let fragmentX = fragment.layoutFragmentFrame.origin.x
        #expect(fragment.renderingSurfaceBounds.minX <= -fragmentX - Self.leading + 0.5)
    }

    @Test("a click in the leading margin beside a gutter item puts the caret in its prefix")
    func marginClick() throws {
        let (tv, window) = try host(config())
        defer { window.contentView = nil }
        window.makeFirstResponder(tv)
        let location = (Self.text as NSString).range(of: "Serve").location
        let bridge = try #require(tv.layoutBridge)
        let container = try #require(tv.textContainer)
        let rect = bridge.boundingRect(forCharacterRange: NSRange(location: location, length: 1), in: container)
        let point = CGPoint(x: rect.minX + tv.textContainerOrigin.x - 30, y: rect.midY + tv.textContainerOrigin.y)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: tv.convert(point, to: nil),
                                       modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        #expect(tv.placeCaretInListGutterIfHit(event: event))
        #expect(tv.selectedRange() == NSRange(location: (Self.text as NSString).range(of: "* 30").location + 4, length: 0))
    }

    @Test("a click in the text hits the character under it, not one shifted by the margin difference")
    func textClickHitsCharacter() throws {
        let (tv, window) = try host(config())
        defer { window.contentView = nil }
        let bridge = try #require(tv.layoutBridge)
        let container = try #require(tv.textContainer)
        let rect = bridge.boundingRect(forCharacterRange: NSRange(location: 10, length: 1), in: container)
        let point = CGPoint(x: rect.minX + 1 + tv.textContainerOrigin.x, y: rect.midY + tv.textContainerOrigin.y)
        #expect(tv.characterIndex(atViewPoint: point) == 10)
    }
}
#endif
