//
//  NativeTextViewCoordinator+VisibleLine.swift
//  MarkdownEngine
//
//  Fork: the line at the top of the visible area, reported while scrolling
//  (`onVisibleTopLine`), and scrolling a line to the top (`SlashCommandProxy.scroll(toLine:)`).
//  Lines are the 0-based, newline-separated lines of the editor's text.
//

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

extension NativeTextViewCoordinator {

    /// The top visible line, or nil without a text view.
    var visibleTopLine: Int? {
        guard let tv = textView else { return nil }
        let origin = tv.textContainerOrigin
        #if os(macOS)
        let inset = tv.enclosingScrollView?.contentInsets.top ?? 0
        #else
        let inset = tv.adjustedContentInset.top
        #endif
        let rect = tv.visibleRect
        let index = tv.characterIndex(atViewPoint: CGPoint(x: rect.minX + origin.x + 1, y: rect.minY + inset + 1))
        return Self.lineIndex(at: index, in: tv.string as NSString)
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
        guard let tv = textView, let bridge = layoutBridge, let container = tv.optionalTextContainer else { return }
        let text = tv.string as NSString
        let lineRange = text.lineRange(for: NSRange(location: Self.lineStart(of: line, in: text), length: 0))
        #if os(iOS)
        // UIKit re-estimates the heights above a line it has just laid out, so lay out all of it first.
        (tv as? NativeTextView)?.ensureFullLayout()
        #endif
        bridge.ensureLayout(forCharacterRange: lineRange)
        var rect = bridge.boundingRect(forCharacterRange: lineRange, in: container)
        if rect == .zero, lineRange.location > 0 {
            // The empty line after a final newline has no text to measure.
            let before = bridge.boundingRect(forCharacterRange: NSRange(location: lineRange.location - 1, length: 1), in: container)
            rect = CGRect(x: before.minX, y: before.maxY, width: before.width, height: before.height)
        }
        let top = rect.minY + tv.textContainerOrigin.y
        #if os(macOS)
        guard let scrollView = tv.enclosingScrollView else { return }
        let clipTop = scrollView.contentView.convert(CGPoint(x: 0, y: top), from: tv).y
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x,
                                                  y: clipTop - scrollView.contentInsets.top))
        (scrollView as? ClampedScrollView)?.clampToInsets()
        scrollView.reflectScrolledClipView(scrollView.contentView)
        #else
        guard tv.isScrollEnabled else { return }
        let minY = -tv.adjustedContentInset.top
        let maxY = max(minY, tv.contentSize.height - tv.bounds.height + tv.adjustedContentInset.bottom)
        tv.setContentOffset(CGPoint(x: tv.contentOffset.x, y: min(max(top + minY, minY), maxY)), animated: false)
        #endif
    }

    /// The 0-based line holding `location`.
    static func lineIndex(at location: Int, in text: NSString) -> Int {
        let end = min(max(location, 0), text.length)
        var line = 0, from = 0
        while from < end {
            let found = text.range(of: "\n", range: NSRange(location: from, length: end - from))
            guard found.location != NSNotFound else { break }
            line += 1
            from = NSMaxRange(found)
        }
        return line
    }

    /// Where `line` starts; the last line's start for a line past the end.
    static func lineStart(of line: Int, in text: NSString) -> Int {
        var start = 0
        for _ in 0..<max(line, 0) {
            let found = text.range(of: "\n", range: NSRange(location: start, length: text.length - start))
            guard found.location != NSNotFound, NSMaxRange(found) < text.length else { break }
            start = NSMaxRange(found)
        }
        return start
    }
}
