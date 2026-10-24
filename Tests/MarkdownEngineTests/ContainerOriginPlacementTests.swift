//
//  ContainerOriginPlacementTests.swift
//  MarkdownEngineTests
//
//  Fork: the text view sits at its container's origin; the header band and the reading column's offset are the
//  container's bounds origin. Live table overlays, which live in the container in a reading column, stay at the
//  column's left edge and span the visible width.
//

#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine
@testable import MarkdownEngineSyntax

@MainActor
@Suite("Container origin placement", .serialized)
struct ContainerOriginPlacementTests {
    private static let source = "Before\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nAfter\n"
    private static let viewport: CGFloat = 900
    private static let columnWidth: CGFloat = 400

    private struct Harness {
        let window: NSWindow
        let container: NativeTextViewContainer
        let textView: NativeTextView
        let coordinator: NativeTextViewCoordinator
        let layoutDelegate = MarkdownLayoutManagerDelegate()

        init(readingWidth: CGFloat?, headerHeight: CGFloat) {
            _ = NSApplication.shared
            var config = MarkdownEditorConfiguration.default
            config.liveTables = true
            config.textInsets = TextInsets(horizontal: 0, vertical: 0)
            config.readingWidth = readingWidth
            let font = NSFont.systemFont(ofSize: 14)
            coordinator = NativeTextViewCoordinator(
                text: .constant(ContainerOriginPlacementTests.source), fontName: font.fontName, fontSize: 14,
                isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil)
            coordinator.configuration = config
            textView = NativeTextView(frame: .zero)
            textView.configuration = config
            textView.baseFont = font
            textView.isEditable = true
            textView.textContainerInset = .zero
            textView.textContainer?.lineFragmentPadding = 0
            if let readingWidth {
                textView.textContainer?.widthTracksTextView = false
                textView.textContainer?.size = NSSize(width: readingWidth, height: .greatestFiniteMagnitude)
            }
            let tlm = textView.textLayoutManager!
            tlm.delegate = layoutDelegate
            coordinator.layoutDelegate = layoutDelegate
            let bridge = LayoutBridge(tlm)
            textView.layoutBridge = bridge
            coordinator.layoutBridge = bridge
            textView.delegate = coordinator
            coordinator.textView = textView

            let frame = NSRect(x: 0, y: 0, width: ContainerOriginPlacementTests.viewport, height: 650)
            let scrollView = ClampedScrollView(frame: frame)
            container = NativeTextViewContainer(frame: frame)
            container.autoresizingMask = [.width]
            container.textView = textView
            textView.frame = NSRect(x: 0, y: 0, width: readingWidth == nil ? frame.width : textView.readingColumnWidth, height: 0)
            container.addSubview(textView)
            scrollView.documentView = container
            window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = scrollView
            window.orderFrontRegardless()
            coordinator.rebuildTextStorageAndStyle(textView, from: ContainerOriginPlacementTests.source, invalidateLayout: true)
            if readingWidth != nil { textView.centerReadingColumn(forClipWidth: frame.width) }
            container.headerHeight = headerHeight
            textView.updateWideTableOverlays(immediately: true)
        }

        var overlay: WideTableOverlay { textView.wideTableOverlays[0]! }
    }

    @Test func theTextViewStaysAtTheContainersOriginUnderAHeaderBandAndAColumnOffset() {
        let h = Harness(readingWidth: Self.columnWidth, headerHeight: 80)
        #expect(h.textView.frame.origin == .zero)
        #expect(h.container.bounds.origin == NSPoint(x: -250, y: -80))
    }

    @Test func aReadingColumnTableOverlaySpansTheVisibleWidthFromTheColumnsLeft() {
        let h = Harness(readingWidth: Self.columnWidth, headerHeight: 80)
        let overlay = h.overlay
        let inWindow = overlay.convert(overlay.bounds, to: nil)
        let textViewLeft = h.textView.convert(NSPoint.zero, to: nil).x
        #expect(abs(inWindow.minX - (textViewLeft - 250)) < 0.5)
        #expect(abs(inWindow.minX - h.window.contentView!.convert(NSPoint.zero, to: nil).x) < 0.5)
        #expect(abs(overlay.frame.width - Self.viewport) < 0.5)
        #expect(abs(overlay.leftContentInset - (250 - TableGridView.gutter)) < 0.5)
    }

    @Test func aTableOverlayIsAsFarBelowTheTextViewsTopWhateverTheHeaderBand() {
        let without = Harness(readingWidth: Self.columnWidth, headerHeight: 0)
        let with = Harness(readingWidth: Self.columnWidth, headerHeight: 80)
        let yWithout = without.overlay.convert(NSPoint.zero, to: without.textView).y
        let yWith = with.overlay.convert(NSPoint.zero, to: with.textView).y
        #expect(yWithout > 0)
        #expect(abs(yWith - yWithout) < 0.5)
    }

    @Test func aFullWidthTableOverlaySitsInTheTextViewAtTheColumnLeft() {
        let h = Harness(readingWidth: nil, headerHeight: 80)
        let overlay = h.overlay
        #expect(overlay.superview === h.textView)
        #expect(abs(overlay.frame.minX - (0 - TableGridView.gutter)) < 0.5)
    }
}
#endif
