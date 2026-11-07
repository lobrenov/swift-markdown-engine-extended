//
//  NativeTextViewCoordinator+VisibleLine.swift
//  MarkdownEngine
//
//  Fork: the line at the top of the visible area, reported while scrolling
//  (`onVisibleTopLine`), and scrolling a line to the top (`SlashCommandProxy.scroll(toLine:)`).
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
    private var token: Any?

    init(scroller: TopLineScroller, coordinator: NativeTextViewCoordinator) {
        self.scroller = scroller
        #if os(macOS)
        let clip = scroller.contentView
        clip.postsBoundsChangedNotifications = true
        token = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) {
            [weak coordinator] _ in coordinator?.reportVisibleTopLine()
        }
        #else
        token = scroller.observe(\.contentOffset, options: []) { [weak coordinator] _, _ in coordinator?.reportVisibleTopLine() }
        #endif
    }

    deinit {
        #if os(macOS)
        if let token { NotificationCenter.default.removeObserver(token) }
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

    /// Follows the current scroller while `onVisibleTopLine` is set; called on updates and when the editor joins a window.
    func observeTopLineScroller() {
        guard onVisibleTopLine != nil else {
            topLineObservation = nil
            return
        }
        let scroller = topLineScroller
        guard topLineObservation?.scroller !== scroller else { return }
        topLineObservation = scroller.map { TopLineObservation(scroller: $0, coordinator: self) }
        reportVisibleTopLine()
    }

    /// The top of the scroller's visible area (below its top inset) in the text view's coordinates.
    private var visibleTop: CGFloat? {
        guard let tv = textView, let scroller = topLineScroller else { return nil }
        #if os(macOS)
        let clip = scroller.contentView
        let inset = scroller.contentInsets.top
        let y = clip.isFlipped ? clip.bounds.minY + inset + 1 : clip.bounds.maxY - inset - 1
        return tv.convert(CGPoint(x: clip.bounds.minX, y: y), from: clip).y
        #else
        return tv.convert(CGPoint(x: 0, y: scroller.bounds.minY + scroller.adjustedContentInset.top + 1), from: scroller).y
        #endif
    }

    /// The top visible line, or nil without a text view or scroller.
    var visibleTopLine: Int? {
        guard let tv = textView, let y = visibleTop else { return nil }
        let index = tv.characterIndex(atViewPoint: CGPoint(x: tv.textContainerOrigin.x + 1, y: y))
        return lineIndex(at: index, in: tv.string as NSString)
    }

    /// Reports the top visible line to `onVisibleTopLine` once the current run-loop turn ends, when it has changed.
    func reportVisibleTopLine() {
        guard onVisibleTopLine != nil, !isTopLineReportPending else { return }
        isTopLineReportPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isTopLineReportPending = false
            guard let onVisibleTopLine, let line = visibleTopLine, line != reportedTopLine else { return }
            reportedTopLine = line
            onVisibleTopLine(line)
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
