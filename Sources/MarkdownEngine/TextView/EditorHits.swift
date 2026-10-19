//
//  EditorHits.swift
//  MarkdownEngine
//
//  Fork: task boxes, callout title lines and tags under a point, and the
//  edits a click, tap or menu makes to them. AppKit's event handling is in
//  `NativeTextView+TaskCheckbox.swift` and `NativeTextView+Callout.swift`;
//  UIKit's gestures in `iOS/NativeTextViewIOS.swift`.
//

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import MarkdownEngineSyntax

extension NativeTextView {
    struct CalloutTitleHit {
        let line: QuoteLine
        let header: CalloutHeader
        let info: CalloutLine
        /// The click, in text-container coordinates.
        let point: CGPoint
    }

    /// The drawn checkbox square under `containerPoint`, if any.
    ///
    /// The `[ ]` chars are collapsed to ~zero width, so their bounding rect sits
    /// at the content edge; reconstruct the DRAWN square from the shared
    /// `TaskCheckboxGeometry` (right-aligned to it). `baseFont`, not
    /// the text view's font (see the draw site). `searchRange` bounds the scan —
    /// the hovered line for cursor checks, nil (whole doc) for clicks.
    func taskCheckboxHit(at containerPoint: CGPoint, in searchRange: NSRange? = nil) -> (range: NSRange, marker: Character, rect: CGRect)? {
        guard let textContainer = optionalTextContainer,
              let bridge = layoutBridge,
              let storage = optionalTextStorage, storage.length > 0 else { return nil }
        let style = configuration.taskCheckbox
        let boxSize = TaskCheckboxGeometry.size(for: baseFont, style: style)
        let scan = searchRange ?? NSRange(location: 0, length: storage.length)
        var hit: (range: NSRange, marker: Character, rect: CGRect)?
        storage.enumerateAttribute(.taskCheckbox, in: scan, options: []) { value, attrRange, stop in
            guard let marker = (value as? String)?.first else { return }
            let anchor = bridge.boundingRect(forCharacterRange: attrRange, in: textContainer)
            let rect = CGRect(
                x: TaskCheckboxGeometry.boxX(contentX: anchor.minX, size: boxSize, style: style),
                y: anchor.minY,
                width: boxSize,
                height: max(anchor.height, boxSize)
            )
            if rect.contains(containerPoint) {
                hit = (attrRange, marker, rect)
                stop.pointee = true
            }
        }
        return hit
    }

    /// The tag of the drawn `#tag` (or its bubble's padding) under a point in the text view's coordinates.
    func tagHit(atViewPoint viewPoint: CGPoint) -> String? {
        guard let textContainer = optionalTextContainer, let bridge = layoutBridge,
              let storage = optionalTextStorage, storage.length > 0 else { return nil }
        let point = CGPoint(x: viewPoint.x - textContainerOrigin.x, y: viewPoint.y - textContainerOrigin.y)
        let padding = configuration.tags?.bubble.horizontalPadding ?? 0
        let index = characterIndex(atViewPoint: viewPoint)
        for location in [index, index - 1] where location >= 0 && location < storage.length {
            var range = NSRange()
            guard let tag = storage.attribute(.markdownTag, at: location, effectiveRange: &range) as? String else { continue }
            if bridge.boundingRect(forCharacterRange: range, in: textContainer).insetBy(dx: -padding, dy: -2).contains(point) {
                return tag
            }
        }
        return nil
    }

    /// The box under a point in the text view's coordinates, if its text still reads as a box.
    func taskCheckboxHit(atViewPoint viewPoint: CGPoint) -> (range: NSRange, marker: Character, rect: CGRect)? {
        let containerPoint = CGPoint(x: viewPoint.x - textContainerOrigin.x, y: viewPoint.y - textContainerOrigin.y)
        guard let hit = taskCheckboxHit(at: containerPoint),
              let storage = optionalTextStorage,
              (storage.string as NSString).substring(with: hit.range)
                .range(of: TaskMarker.boxPattern, options: .regularExpression) != nil else { return nil }
        return hit
    }

    /// Applies the click transition to `hit`'s box.
    func toggleTaskCheckbox(_ hit: (range: NSRange, marker: Character, rect: CGRect)) {
        if let next = configuration.taskCheckbox.clickTransitions[hit.marker] {
            setTaskMarker(next, boxRange: hit.range)
        }
    }

    /// The request `onTaskMarkerMenu` gets for `hit`.
    func taskMarkerMenuRequest(for hit: (range: NSRange, marker: Character, rect: CGRect)) -> TaskMarkerMenuRequest {
        let boxText = "[\(hit.marker)]"
        let viewRect = hit.rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        return TaskMarkerMenuRequest(marker: hit.marker, anchorRect: menuAnchorRect(forViewRect: viewRect)) { [weak self] marker in
            guard let self, let storage = self.optionalTextStorage, NSMaxRange(hit.range) <= storage.length,
                  (storage.string as NSString).substring(with: hit.range) == boxText else { return }
            self.setTaskMarker(marker, boxRange: hit.range)
        }
    }

    /// Replaces the marker character inside `[…]`, as one undoable edit.
    func setTaskMarker(_ marker: Character, boxRange: NSRange) {
        guard let storage = optionalTextStorage, let bridge = layoutBridge else { return }
        let replacement = "[\(marker)]"
        guard shouldChangeText(in: boxRange, replacementString: replacement) else { return }
        storage.replaceCharacters(in: boxRange, with: replacement)
        storage.addAttribute(.taskCheckbox, value: String(marker), range: boxRange)
        storage.addAttribute(.foregroundColor, value: PlatformColor.clear, range: boxRange)
        didChangeText()
        bridge.invalidateDisplay(forCharacterRange: boxRange)
        if let coord = delegate as? NativeTextViewCoordinator {
            let paragraph = (storage.string as NSString).paragraphRange(for: boxRange)
            coord.restyleParagraphs([paragraph], in: self)
        }
    }
    func calloutTitleHit(atViewPoint viewPoint: CGPoint) -> CalloutTitleHit? {
        guard configuration.callouts != nil, let storage = optionalTextStorage, storage.length > 0,
              let container = optionalTextContainer, let bridge = layoutBridge else { return nil }
        let point = CGPoint(x: viewPoint.x - textContainerOrigin.x, y: viewPoint.y - textContainerOrigin.y)
        let ns = storage.string as NSString
        let index = min(characterIndex(atViewPoint: viewPoint), ns.length - 1)
        guard index >= 0 else { return nil }
        let line = QuoteLine.parse(ns.lineRange(for: NSRange(location: index, length: 0)), of: ns)
        guard line.level > 0, line.text.length > 0,
              let info = storage.attribute(.calloutLine, at: line.text.location, effectiveRange: nil) as? CalloutLine,
              info.isTitle, let header = CalloutHeader.parse(ns, content: line.content) else { return nil }
        let rect = bridge.boundingRect(forCharacterRange: line.text, in: container)
        guard point.y >= rect.minY, point.y < rect.maxY else { return nil }
        return CalloutTitleHit(line: line, header: header, info: info, point: point)
    }

    /// Folds or opens the callout when `hit` lands on its title row outside the title text. Returns true when
    /// it did.
    func toggleCalloutFold(_ hit: CalloutTitleHit) -> Bool {
        guard hit.header.fold.length == 1, let title = hit.info.title,
              let storage = optionalTextStorage, let container = optionalTextContainer, let bridge = layoutBridge,
              let coordinator = delegate as? NativeTextViewCoordinator else { return false }
        // The title text places the caret; the rest of the row folds.
        if hit.header.title.length > 0 {
            let titleRect = bridge.boundingRect(forCharacterRange: hit.header.title, in: container)
            let chevronX = container.size.width - title.chevronRightInset - title.chevronSize - 4
            // A wrapped title runs to the chevron.
            let titleEnd = titleRect.height > title.font.pointSize * 2.5 ? chevronX : titleRect.maxX
            if hit.point.x >= title.nameX, hit.point.x <= titleEnd { return false }
        }
        let ns = storage.string as NSString
        let key = ns.substring(with: hit.line.text)
        let folding = !hit.info.isFolded
        let fileFolds = ns.character(at: hit.header.fold.location) == 0x2D /* - */
        coordinator.configuration.calloutFoldOverrides[key] = folding == fileFolds ? nil : folding
        // A caret in the body keeps it open.
        let callout = calloutRange(titledBy: hit.line, in: ns)
        if folding, NSLocationInRange(currentSelectedRange.location, callout),
           currentSelectedRange.location > NSMaxRange(hit.line.text) {
            setSelectedRange(NSRange(location: NSMaxRange(hit.line.text), length: 0))
        }
        coordinator.restyleParagraphs([callout], in: self)
        return true
    }

    /// Hands a right-click (or press and hold) on a title line to `onCalloutMenu`, ringing the callout until the menu closes.
    func showCalloutMenu(for hit: CalloutTitleHit, _ onCalloutMenu: (CalloutMenuRequest) -> Void) {
        guard let storage = optionalTextStorage, let container = optionalTextContainer, let bridge = layoutBridge else { return }
        let ns = storage.string as NSString
        let titleLine = hit.line.text
        let lineText = ns.substring(with: titleLine)
        let callout = calloutRange(titledBy: hit.line, in: ns)
        let lineRect = bridge.boundingRect(forCharacterRange: titleLine, in: container)
        let iconX = hit.info.title?.iconX ?? bridge.boundingRect(forCharacterRange: hit.header.syntax, in: container).minX
        let iconSize = hit.info.title?.iconSize ?? lineRect.height
        let viewRect = CGRect(x: iconX, y: lineRect.minY, width: iconSize, height: lineRect.height)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        let anchor = menuAnchorRect(forViewRect: viewRect)

        calloutMenuTarget = titleLine.location
        bridge.invalidateDisplay(forCharacterRange: callout)
        let header = hit.header
        let fold = header.fold.length == 1 ? Character(ns.substring(with: header.fold)) : nil
        // Edits apply only while the title line still reads as it did.
        let edit: @MainActor (NSRange, String) -> Void = { [weak self] range, text in
            guard let self, let storage = self.optionalTextStorage, NSMaxRange(titleLine) <= storage.length,
                  (storage.string as NSString).substring(with: titleLine) == lineText,
                  (storage.string as NSString).substring(with: range) != text else { return }
            self.breakUndoCoalescing()
            guard self.shouldChangeText(in: range, replacementString: text) else { return }
            storage.replaceCharacters(in: range, with: text)
            self.didChangeText()
        }
        onCalloutMenu(CalloutMenuRequest(
            type: ns.substring(with: header.type), fold: fold, anchorRect: anchor,
            setType: { edit(header.type, $0) },
            setFold: { edit(header.fold, $0.map { String($0) } ?? "") },
            close: { [weak self] in
                guard let self, self.calloutMenuTarget == titleLine.location else { return }
                self.calloutMenuTarget = nil
                let length = self.optionalTextStorage?.length ?? 0
                self.layoutBridge?.invalidateDisplay(forCharacterRange: NSIntersectionRange(callout, NSRange(location: 0, length: length)))
            }))
    }

    /// The title line and the lines after it at its level or deeper.
    func calloutRange(titledBy title: QuoteLine, in ns: NSString) -> NSRange {
        var end = NSMaxRange(title.line)
        while end < ns.length {
            let next = QuoteLine.parse(ns.lineRange(for: NSRange(location: end, length: 0)), of: ns)
            guard next.level >= title.level else { break }
            end = NSMaxRange(next.line)
        }
        return NSRange(location: title.line.location, length: end - title.line.location)
    }
}
