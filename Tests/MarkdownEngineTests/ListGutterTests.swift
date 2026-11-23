//
//  ListGutterTests.swift
//  MarkdownEngineTests
//
//  Fork: list gutter items (`ListStyle.gutterPrefix`), emphasized list prefixes (`ListStyle.emphasizedPrefix`) and
//  overlay scrollers (`ScrollersPolicy.forcesOverlay`). A gutter item drops its bullet and indent so its content
//  starts at the body text's left edge; its marker and prefix collapse, and the prefix's label is drawn in the
//  margin to the left. Clicking the margin puts the caret inside the prefix.
//

// Fork: macOS only.
#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Fork — list gutter")
struct ListGutterTests {
    /// `*` items are gutter items: `N min: ` → label "N min", caret after the number;
    /// a `*` item without a time gets no label. `-` items stay ordinary bullets.
    static let steps: @Sendable (Character, String) -> ListGutterPrefix? = { marker, content in
        guard marker == "*" else { return nil }
        let ns = content as NSString
        guard let match = try! NSRegularExpression(pattern: #"^(\d+) min: "#)
            .firstMatch(in: content, range: NSRange(location: 0, length: ns.length)) else {
            return ListGutterPrefix(length: 0, label: nil)
        }
        let number = ns.substring(with: match.range(at: 1))
        return ListGutterPrefix(length: match.range.length, label: "\(number) min",
                                caretOffset: match.range(at: 1).length)
    }

    static let text = "Intro paragraph.\n\n* 30 min: Serve.\n* Rest.\n- 45 min: a bullet\n"
    static func location(of needle: String) -> Int { (text as NSString).range(of: needle).location }

    /// Objects the editor only holds weakly, kept alive for the length of a test.
    private final class Retained {
        var bridge: LayoutBridge?
        let layoutDelegate = MarkdownLayoutManagerDelegate()
    }
    private let retained = Retained()

    private func makeEditor(_ text: String = Self.text,
                            configure: (inout MarkdownEditorConfiguration) -> Void = { _ in })
        -> (NativeTextViewCoordinator, NativeTextView, NSWindow) {
        _ = NSApplication.shared
        let coordinator = NativeTextViewCoordinator(
            text: .constant(text), fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        coordinator.configuration.lists.gutterPrefix = Self.steps
        configure(&coordinator.configuration)
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.configuration = coordinator.configuration
        tv.textContainerInset = NSSize(width: 80, height: 0)   // the margin the labels sit in
        tv.isEditable = true
        if let tlm = tv.textLayoutManager {
            tlm.delegate = retained.layoutDelegate
            retained.bridge = LayoutBridge(tlm)
            tv.layoutBridge = retained.bridge
            coordinator.layoutBridge = retained.bridge
        }
        tv.delegate = coordinator
        coordinator.textView = tv
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = tv
        window.makeFirstResponder(tv)
        coordinator.rebuildTextStorageAndStyle(tv, from: text)
        coordinator.lastSyncedText = text
        coordinator.lastComputedStorage = text
        coordinator.previousDisplayLength = (text as NSString).length
        tv.setSelectedRange(NSRange(location: 0, length: 0))     // caret in the intro
        tv.textLayoutManager?.ensureLayout(for: tv.textLayoutManager!.documentRange)
        return (coordinator, tv, window)
    }

    /// View-space point at the left edge of a character, vertically centred on its line.
    private func pointOfCharacter(_ index: Int, in tv: NativeTextView) throws -> CGPoint {
        let bridge = try #require(tv.layoutBridge)
        let container = try #require(tv.textContainer)
        let rect = bridge.boundingRect(forCharacterRange: NSRange(location: index, length: 1), in: container)
        return CGPoint(x: rect.minX + tv.textContainerOrigin.x, y: rect.midY + tv.textContainerOrigin.y)
    }

    /// A single click at a view-space point, through the real mouseDown entry point.
    /// A miss falls through to AppKit's modal click tracking, which a headless test
    /// can't drive: it hangs rather than fails, so run these under a timeout.
    private func click(_ tv: NativeTextView, at point: CGPoint, in window: NSWindow) {
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: tv.convert(point, to: nil),
                                       modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        tv.mouseDown(with: event)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))  // deferred selection / restyle work
    }

    private func attribute(_ key: NSAttributedString.Key, at index: Int, in tv: NativeTextView) -> Any? {
        tv.textStorage?.attribute(key, at: index, effectiveRange: nil)
    }

    // MARK: Layout

    @Test("a gutter item's content starts at the body text's left edge")
    func contentAlignsWithBody() throws {
        let (_, tv, window) = makeEditor()
        defer { window.contentView = nil }
        let body = try pointOfCharacter(0, in: tv).x
        #expect(abs(try pointOfCharacter(Self.location(of: "Serve"), in: tv).x - body) < 1)
        #expect(abs(try pointOfCharacter(Self.location(of: "Rest"), in: tv).x - body) < 1)
    }

    @Test("a timed gutter item carries its label; an untimed one has none and no bullet")
    func labelsAndBullets() {
        let (_, tv, window) = makeEditor()
        defer { window.contentView = nil }
        #expect(attribute(.listGutterLabel, at: Self.location(of: "* 30"), in: tv) as? String == "30 min")
        #expect(attribute(.listGutterLabel, at: Self.location(of: "* Rest"), in: tv) == nil)
        #expect(attribute(.bulletMarker, at: Self.location(of: "* Rest"), in: tv) == nil)
        // Not a gutter item: an ordinary bullet, time and all.
        #expect(attribute(.bulletMarker, at: Self.location(of: "- 45"), in: tv) as? Bool == true)
        #expect(attribute(.listGutterLabel, at: Self.location(of: "- 45"), in: tv) == nil)
    }

    @Test("with the caret in the prefix, the raw source shows at the body's left edge")
    func caretRevealsSource() throws {
        let (_, tv, window) = makeEditor()
        defer { window.contentView = nil }
        tv.setSelectedRange(NSRange(location: Self.location(of: "30") + 1, length: 0))
        #expect(attribute(.listGutterLabel, at: Self.location(of: "* 30"), in: tv) == nil)
        let body = try pointOfCharacter(0, in: tv).x
        #expect(abs(try pointOfCharacter(Self.location(of: "* 30"), in: tv).x - body) < 1)
        #expect(try pointOfCharacter(Self.location(of: "Serve"), in: tv).x > body + 20)
    }

    @Test("the label is painted in the margin, not clipped to the text column")
    func labelIsPainted() throws {
        let (_, tv, window) = makeEditor()
        defer { window.contentView = nil }
        tv.appearance = NSAppearance(named: .aqua)
        tv.drawsBackground = true
        tv.backgroundColor = .white
        let rep = try #require(tv.bitmapImageRepForCachingDisplay(in: tv.bounds))
        tv.cacheDisplay(in: tv.bounds, to: rep)

        /// Non-white pixels in a view-space rect.
        func ink(in rect: CGRect) -> Int {
            let scale = CGFloat(rep.pixelsWide) / tv.bounds.width
            var count = 0
            for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
                for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if color.redComponent + color.greenComponent + color.blueComponent < 2.7 { count += 1 }
                }
            }
            return count
        }
        let timed = try pointOfCharacter(Self.location(of: "Serve"), in: tv)
        let untimed = try pointOfCharacter(Self.location(of: "Rest"), in: tv)
        let margin = { (p: CGPoint) in CGRect(x: p.x - 70, y: p.y - 6, width: 66, height: 12) }
        #expect(ink(in: margin(timed)) > 20)
        #expect(ink(in: margin(untimed)) == 0)
    }

    // MARK: Clicks

    @Test("clicking the margin puts the caret after the number", arguments: [4, 20, 60])
    func clickInMargin(pointsLeftOfContent: CGFloat) throws {
        let (_, tv, window) = makeEditor()
        defer { window.contentView = nil }
        let content = try pointOfCharacter(Self.location(of: "Serve"), in: tv)
        click(tv, at: CGPoint(x: content.x - pointsLeftOfContent, y: content.y), in: window)
        #expect(tv.selectedRange() == NSRange(location: Self.location(of: "* 30") + 4, length: 0))
    }

    @Test("clicking the margin of an untimed item puts the caret at its content")
    func clickInUntimedMargin() throws {
        let (_, tv, window) = makeEditor()
        defer { window.contentView = nil }
        let content = try pointOfCharacter(Self.location(of: "Rest"), in: tv)
        click(tv, at: CGPoint(x: content.x - 20, y: content.y), in: window)
        #expect(tv.selectedRange() == NSRange(location: Self.location(of: "Rest"), length: 0))
    }

    /// A typical host: the SwiftUI wrapper in a window, reading column, margin insets, header.
    @Test("clicking the margin in the hosted editor", arguments: [false, true])
    func clickInHostedEditor(withHeader: Bool) throws {
        _ = NSApplication.shared
        var config = MarkdownEditorConfiguration.default
        config.readingWidth = 500
        config.textInsets = TextInsets(horizontal: 80)
        config.lists.gutterPrefix = Self.steps
        let editor = NativeTextViewWrapper(
            text: .constant(Self.text), configuration: config, documentId: "doc",
            header: withHeader ? AnyView(Text("Header").frame(height: 60)) : nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: editor)
        defer { window.contentView = nil }
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        func find(_ view: NSView) -> NativeTextView? {
            if let tv = view as? NativeTextView { return tv }
            return view.subviews.lazy.compactMap(find).first
        }
        let tv = try #require(find(window.contentView!))
        window.makeFirstResponder(tv)
        tv.textLayoutManager?.ensureLayout(for: tv.textLayoutManager!.documentRange)
        let content = try pointOfCharacter(Self.location(of: "Serve"), in: tv)
        click(tv, at: CGPoint(x: content.x - 30, y: content.y), in: window)
        #expect(tv.selectedRange() == NSRange(location: Self.location(of: "* 30") + 4, length: 0))
    }

    // MARK: Emphasized prefixes

    /// A leading number and unit, like `2 tbsp`.
    static let quantity: @Sendable (String) -> Int? = { content in
        let ns = content as NSString
        return try! NSRegularExpression(pattern: #"^\d+( tbsp)?"#)
            .firstMatch(in: content, range: NSRange(location: 0, length: ns.length))?.range.length
    }

    static let quantities = "- [ ] 2 tbsp olive oil\n- 400 g pasta\n- Salt\n"
    static func quantity(_ needle: String) -> Int { (quantities as NSString).range(of: needle).location }

    @Test("an emphasized prefix is bold, in its colour, in task and plain items")
    func emphasizedPrefixIsBold() throws {
        let (_, tv, window) = makeEditor(Self.quantities) {
            $0.lists.emphasizedPrefix = Self.quantity
            $0.lists.emphasizedPrefixColor = .systemYellow
        }
        defer { window.contentView = nil }
        func isBold(_ index: Int) -> Bool {
            (attribute(.font, at: index, in: tv) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true
        }
        for index in [Self.quantity("2 tbsp"), Self.quantity("tbsp") + 3, Self.quantity("400")] {
            #expect(isBold(index))
            #expect(attribute(.foregroundColor, at: index, in: tv) as? NSColor == .systemYellow)
        }
        #expect(!isBold(Self.quantity("olive")))
        #expect(!isBold(Self.quantity(" g pasta") + 1))
        #expect(!isBold(Self.quantity("Salt")))
        #expect(attribute(.foregroundColor, at: Self.quantity("olive"), in: tv) as? NSColor != .systemYellow)
    }

    @Test("without the hook, list items aren't emphasized")
    func noEmphasisByDefault() {
        let (_, tv, window) = makeEditor(Self.quantities)
        defer { window.contentView = nil }
        let font = attribute(.font, at: Self.quantity("2 tbsp"), in: tv) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == false)
    }

    // MARK: Overlay scrollers

    @Test("overlay scrollers stay overlay, with the configured knob, whatever the system prefers")
    func overlayScrollers() throws {
        _ = NSApplication.shared
        var config = MarkdownEditorConfiguration.default
        config.scrollers.forcesOverlay = true
        config.scrollers.knobStyle = .light
        let editor = NativeTextViewWrapper(text: .constant(Self.text), configuration: config, documentId: "doc")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: editor)
        defer { window.contentView = nil }
        window.layoutIfNeeded()

        func find(_ view: NSView) -> NSScrollView? {
            if let scrollView = view as? ClampedScrollView { return scrollView }
            return view.subviews.lazy.compactMap(find).first
        }
        let scrollView = try #require(find(window.contentView!))
        #expect(scrollView.scrollerStyle == .overlay)
        #expect(scrollView.scrollerKnobStyle == .light)
        scrollView.scrollerStyle = .legacy   // as AppKit does when the system setting changes
        #expect(scrollView.scrollerStyle == .overlay)
    }
}
#endif
