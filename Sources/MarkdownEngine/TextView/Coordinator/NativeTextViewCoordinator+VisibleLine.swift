//
//  NativeTextViewCoordinator+VisibleLine.swift
//  MarkdownEngine
//
//  Fork: the lines at least partly visible, reported while scrolling
//  (`onVisibleLines`), and scrolling a line to the top (`SlashCommandProxy.scroll(toLine:)`).
//  Lines are the 0-based lines of the editor's text, split as the block parser splits them (`\n`, `\r\n`, `\r`,
//  U+2028, U+2029, U+0085). The scroller is the editor's own scroll view, or with `.fitsContent` the nearest
//  ancestor scroll view.
//

#if canImport(AppKit)
import AppKit
typealias TopLineScroller = NSScrollView
#else
import UIKit
typealias TopLineScroller = UIScrollView
#endif

/// Watches a scroller's offset and reports the coordinator's top line when it changes.
final class TopLineObservation {
    weak var scroller: TopLineScroller?
    private var tokens: [Any] = []

    /// Reports when the scroller scrolls or the text view is resized: a text view that grows as its text lays out
    /// moves the bottom edge's line without the scroller moving.
    init(scroller: TopLineScroller, textView: PlatformTextView, coordinator: NativeTextViewCoordinator) {
        self.scroller = scroller
        #if os(macOS)
        let clip = scroller.contentView
        clip.postsBoundsChangedNotifications = true
        textView.postsFrameChangedNotifications = true
        for (name, object) in [(NSView.boundsDidChangeNotification, clip as NSView), (NSView.frameDidChangeNotification, textView)] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) {
                [weak coordinator] _ in coordinator?.reportVisibleLines()
            })
        }
        #else
        tokens.append(scroller.observe(\.contentOffset, options: []) { [weak coordinator] _, _ in coordinator?.reportVisibleLines() })
        tokens.append(textView.observe(\.contentSize, options: []) { [weak coordinator] _, _ in coordinator?.reportVisibleLines() })
        tokens.append(textView.observe(\.bounds, options: []) { [weak coordinator] _, _ in coordinator?.reportVisibleLines() })
        #endif
    }

    deinit {
        #if os(macOS)
        tokens.forEach(NotificationCenter.default.removeObserver(_:))
        #endif
    }
}

extension NativeTextViewCoordinator {

    /// The scroll view whose offset says what is visible.
    var topLineScroller: TopLineScroller? {
        guard let tv = textView else { return nil }
        let fits = configuration.heightBehavior == .fitsContent
        #if os(macOS)
        let own = tv.enclosingScrollView
        return fits ? own?.enclosingScrollView : own
        #else
        guard fits else { return tv }
        var view = tv.superview
        while let candidate = view {
            if let scroller = candidate as? UIScrollView { return scroller }
            view = candidate.superview
        }
        return nil
        #endif
    }

    /// Follows the current scroller while `onVisibleLines` is set; called on updates and when the editor joins a window.
    func observeTopLineScroller() {
        guard onVisibleLines != nil else {
            topLineObservation = nil
            return
        }
        let scroller = topLineScroller
        // Every update: the text may have changed, and with it the lines in view.
        defer { reportVisibleLines() }
        guard topLineObservation?.scroller !== scroller else { return }
        topLineObservation = textView.flatMap { tv in scroller.map { TopLineObservation(scroller: $0, textView: tv, coordinator: self) } }
    }

    /// The top and bottom of the scroller's visible area (inside its insets) in the text view's coordinates.
    private var visibleEdges: (top: CGFloat, bottom: CGFloat)? {
        guard let tv = textView, let scroller = topLineScroller else { return nil }
        #if os(macOS)
        let clip = scroller.contentView
        let (top, bottom) = (scroller.contentInsets.top + 1, scroller.contentInsets.bottom + 1)
        let (topY, bottomY) = clip.isFlipped ? (clip.bounds.minY + top, clip.bounds.maxY - bottom)
                                             : (clip.bounds.maxY - top, clip.bounds.minY + bottom)
        let x = clip.bounds.minX
        return (tv.convert(CGPoint(x: x, y: topY), from: clip).y, tv.convert(CGPoint(x: x, y: bottomY), from: clip).y)
        #else
        let top = scroller.bounds.minY + scroller.adjustedContentInset.top + 1
        let bottom = scroller.bounds.maxY - scroller.adjustedContentInset.bottom - 1
        return (tv.convert(CGPoint(x: 0, y: top), from: scroller).y, tv.convert(CGPoint(x: 0, y: bottom), from: scroller).y)
        #endif
    }

    /// The first and last lines at least partly visible, or nil without a text view or scroller.
    var visibleLines: ClosedRange<Int>? {
        guard let tv = textView, let edges = visibleEdges else { return nil }
        let text = tv.string as NSString
        // A scroller above or below the editor (a page with a title over it) shows none of its text at that edge: a point
        // outside the text view hits the end of the text, so the edge is held to the text's own extent.
        #if os(iOS)
        let extent = tv.isScrollEnabled ? tv.contentSize.height : tv.bounds.height
        #else
        let extent = tv.bounds.height
        #endif
        func line(_ y: CGFloat) -> Int {
            let held = min(max(y, tv.textContainerOrigin.y + 1), max(tv.textContainerOrigin.y + 1, extent - tv.textContainerOrigin.y - 1))
            return lineIndex(at: tv.characterIndex(atViewPoint: CGPoint(x: tv.textContainerOrigin.x + 1, y: held)), in: text)
        }
        let first = line(edges.top)
        return first...max(first, line(edges.bottom))
    }

    /// Reports the visible lines to `onVisibleLines` once the current run-loop turn ends, when it has changed.
    func reportVisibleLines() {
        guard onVisibleLines != nil, !isLinesReportPending else { return }
        isLinesReportPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isLinesReportPending = false
            guard let onVisibleLines, let lines = visibleLines, lines != reportedLines else { return }
            reportedLines = lines
            onVisibleLines(lines)
        }
    }

    /// Scrolls `line` to the top of the visible area; a line past the end scrolls to the last one.
    func scroll(toLine line: Int) {
        guard let tv = textView, let bridge = layoutBridge, let container = tv.optionalTextContainer,
              let scroller = topLineScroller else { return }
        let text = tv.string as NSString
        let starts = lineStarts(of: text)
        let lineRange = text.lineRange(for: NSRange(location: starts[min(max(line, 0), starts.count - 1)], length: 0))
        #if os(iOS)
        // UIKit re-estimates the heights above a line it has just laid out, so lay out everything above it.
        if tv.isScrollEnabled {
            bridge.ensureLayout(forCharacterRange: NSRange(location: 0, length: NSMaxRange(lineRange)))
            tv.layoutIfNeeded()
        }
        #else
        bridge.ensureLayout(forCharacterRange: lineRange)
        #endif
        let rect = bridge.boundingRect(forCharacterRange: lineRange, in: container)
        let top = rect.minY + tv.textContainerOrigin.y
        #if os(macOS)
        let clip = scroller.contentView
        let clipTop = clip.convert(CGPoint(x: 0, y: top), from: tv).y
        let minY = -scroller.contentInsets.top
        var y = clipTop - scroller.contentInsets.top
        if !(scroller is ClampedScrollView), let document = scroller.documentView {
            y = min(max(y, minY), max(minY, document.frame.height - clip.bounds.height))
        }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        (scroller as? ClampedScrollView)?.clampToInsets()
        scroller.reflectScrolledClipView(clip)
        #else
        let minY = -scroller.adjustedContentInset.top
        let maxY = max(minY, scroller.contentSize.height - scroller.bounds.height + scroller.adjustedContentInset.bottom)
        let y = scroller.convert(CGPoint(x: 0, y: top), from: tv).y + minY
        scroller.setContentOffset(CGPoint(x: scroller.contentOffset.x, y: min(max(y, minY), maxY)), animated: false)
        #endif
    }

    /// Where each line of `text` starts, cached until the text changes.
    func lineStarts(of text: NSString) -> [Int] {
        if let cached = lineStartsCache, cached.text.isEqual(to: text as String) { return cached.starts }
        var starts = [0]
        var cursor = 0
        while cursor < text.length {
            cursor = NSMaxRange(text.lineRange(for: NSRange(location: cursor, length: 0)))
            if cursor < text.length { starts.append(cursor) }
        }
        lineStartsCache = (text.copy() as! NSString, starts)
        return starts
    }

    /// The 0-based line holding `location`.
    func lineIndex(at location: Int, in text: NSString) -> Int {
        let starts = lineStarts(of: text)
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }
}
