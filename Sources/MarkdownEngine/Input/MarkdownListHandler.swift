//
//  MarkdownListHandler.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Makes list editing feel natural by continuing items, handling indentation,
// and applying spacing/alignment that keeps lists easy to read.
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

struct MarkdownLists {
    static func performEdit(_ textView: PlatformTextView, replace range: NSRange, with string: String) {
        let ns = textView.string as NSString
        let loc = min(range.location, ns.length)
        let maxLen = ns.length - loc
        let len = min(range.length, max(0, maxLen))
        let safeRange = NSRange(location: loc, length: len)

        if let coord = textView.delegate as? NativeTextViewWrapper.Coordinator {
            coord.isProgrammaticEdit = true
            // This edit REPLACES a suppressed keystroke that never applied.
            // Dropping its pending count lets the shouldChangeText below
            // re-register as the cycle's single tracked edit, so textDidChange
            // keeps the trusted fast paths (the descriptor is refreshed for
            // every proposed edit and describes THIS transition exactly).
            coord.pendingEditCount = 0
        }
        defer {
            if let coord = textView.delegate as? NativeTextViewWrapper.Coordinator { coord.isProgrammaticEdit = false }
        }

        #if os(macOS)
        guard textView.shouldChangeText(in: safeRange, replacementString: string) else { return }
        textView.optionalTextStorage?.replaceCharacters(in: safeRange, with: string)
        textView.didChangeText()
        #else
        textView.replaceCharacters(in: safeRange, with: string)
        #endif
    }

    // Markers: `-`/`*`/`+` (raw Markdown) + legacy `•` (rendered, never typed).
    static let listRegex = try! NSRegularExpression(
        pattern: #"^\s*((?:(\d+)\.|[-•*+])(?:\s+"# + TaskMarker.boxPattern + #")?\s+)"#
    )
    /// Blockquote line: ≤3 indent + `>` marker run; group 1 = whitespace, group 2 = markers.
    // Trailing `[ \t]*` so the prefix length covers the space(s) the continuation
    // inserts (`markers + " "`) — otherwise exiting an empty quote leaves a stray
    // space (greedy like listRegex's `\s+`).
    static let blockquoteRegex = try! NSRegularExpression(
        pattern: #"^( {0,3})(>+(?:[ \t]+>+)*)[ \t]*"#
    )
    static let dashNoSpaceRegex = try! NSRegularExpression(pattern: #"^\s*-(?!\s)"#)
    static let leadingWhitespaceRegex = try! NSRegularExpression(pattern: #"^\s*"#)

    static func indentLevel(from leadingWhitespace: String) -> Int {
        let tabCount = leadingWhitespace.filter { $0 == "\t" }.count
        let spaceCount = leadingWhitespace.filter { $0 == " " }.count
        return tabCount + (spaceCount / 2)
    }

    /// Remove the current line's leading marker from `start` and put the caret there (exit empty block on Enter).
    /// Fork: `start` keeps a quote marker before a list marker.
    private static func removeLinePrefixAndExit(
        textView: PlatformTextView,
        currentLineRange: NSRange,
        from start: Int = 0,
        prefixLength: Int
    ) -> Bool {
        let lineEnd = currentLineRange.location + currentLineRange.length
        let hasNewline = currentLineRange.length > 0
            && (textView.string as NSString)
                .substring(with: NSRange(location: lineEnd - 1, length: 1)) == "\n"
        let maxBodyLen = hasNewline ? currentLineRange.length - 1 : currentLineRange.length
        let removalLength = min(prefixLength, maxBodyLen) - start
        let removalRange = NSRange(location: currentLineRange.location + start, length: removalLength)
        performEdit(textView, replace: removalRange, with: "")
        textView.setSelectedRange(NSRange(location: currentLineRange.location + start, length: 0))
        return false
    }

    /// Mirror Enter-key quote continuation for multi-line pastes: when `location`
    /// sits on a blockquote line, prefix every line after the first with that
    /// line's `>` marker run so the whole paste stays inside the quote. Returns
    /// `pasted` unchanged when it has no newline or the caret isn't in a quote.
    static func blockquoteContinuedPaste(_ pasted: String, at location: Int, in document: String) -> String {
        guard pasted.contains("\n") else { return pasted }
        let ns = document as NSString
        guard location >= 0, location <= ns.length else { return pasted }
        let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
        let nsLine = ns.substring(with: lineRange) as NSString
        guard let match = blockquoteRegex.firstMatch(
            in: nsLine as String,
            range: NSRange(location: 0, length: nsLine.length)
        ) else { return pasted }
        let ws = nsLine.substring(with: match.range(at: 1))
        let markers = nsLine.substring(with: match.range(at: 2))
        let prefix = ws + markers + " "
        return pasted.replacingOccurrences(of: "\n", with: "\n" + prefix)
    }

    // MARK: - Input Handling

    /// `isInsideCodeBlock` is the caller's pre-parsed answer for
    /// `affectedCharRange.location` (the coordinator derives it from the
    /// keystroke's existing parse). `nil` — direct callers without a parse —
    /// falls back to deriving it here, which walks the whole document.
    static func handleInsertion(textView: PlatformTextView, affectedCharRange: NSRange, replacementString: String?, isInsideCodeBlock: Bool? = nil) -> Bool {
        guard let replacementString = replacementString else { return true }

        // Fast path: plain characters never trigger list/pair/arrow handling.
        if replacementString.count == 1,
           let ch = replacementString.first,
           ch != ">" && ch != "\t" && ch != " " && ch != "\n",
           !MarkdownAutoPairs.triggers.contains(ch) {
            return true
        }

        let activeConfig = (textView as? NativeTextView)?.configuration ?? .default
        let listsEnabled = activeConfig.lists.helpersEnabled

        let isInCodeBlock = isInsideCodeBlock ?? (
            textView.string.contains("`")
                ? MarkdownDetection.isInsideCodeBlock(location: affectedCharRange.location, in: textView.string)
                : false
        )

        if replacementString == ">" && affectedCharRange.length == 0 && !isInCodeBlock {
            let insertionLocation = affectedCharRange.location
            guard insertionLocation > 0 else { return true }
            let nsText = textView.string as NSString
            let previousCharRange = NSRange(location: insertionLocation - 1, length: 1)
            let previousChar = nsText.substring(with: previousCharRange)
            if previousChar == "-" {
                MarkdownLists.performEdit(textView, replace: previousCharRange, with: "→")
                textView.setSelectedRange(NSRange(location: insertionLocation, length: 0))
                return false
            }
        }

        // Fork: brackets, formatting markers and wiki links pair, and an added closer is stepped over.
        if let handled = MarkdownAutoPairs.handleInsertion(
            textView, range: affectedCharRange, replacement: replacementString, isInCodeBlock: isInCodeBlock
        ) {
            return handled
        }

        // TAB: indent list items (skip in code blocks)
        if replacementString == "\t" && !isInCodeBlock {
            guard listsEnabled else { return true }
            let nsText = textView.string as NSString
            let insertionLocation = affectedCharRange.location
            let safeLocTAB = min(affectedCharRange.location, nsText.length)
            let currentLineRange = nsText.lineRange(for: NSRange(location: safeLocTAB, length: 0))
            let currentLine = nsText.substring(with: currentLineRange)
            // Fork: every selected list line (and its children), only under a previous sibling.
            let maximumLevel = (textView as? NativeTextView)?.configuration.lists.maximumNestingLevel
                ?? MarkdownEditorConfiguration.default.lists.maximumNestingLevel
            if MarkdownLists.indentListLines(textView, selection: affectedCharRange, maximumLevel: maximumLevel) != nil {
                return false
            }
            if MarkdownLists.dashNoSpaceRegex.firstMatch(in: currentLine, range: NSRange(location: 0, length: currentLine.utf16.count)) != nil {
                if let wsMatch = MarkdownLists.leadingWhitespaceRegex.firstMatch(in: currentLine, range: NSRange(location: 0, length: currentLine.utf16.count)) {
                    let ws = (currentLine as NSString).substring(with: wsMatch.range)
                    let level = MarkdownLists.indentLevel(from: ws)
                    if level >= MarkdownEditorConfiguration.default.lists.maximumNestingLevel { return false }
                }
                MarkdownLists.performEdit(textView, replace: NSRange(location: currentLineRange.location, length: 0), with: "\t")
                textView.setSelectedRange(NSRange(location: insertionLocation + 1, length: 0))
                return false
            }
            return true
        }

        // ENTER: list continuation/outdent
        if replacementString == "\n" {
            let nsText = textView.string as NSString
            let safeLocENTER = min(affectedCharRange.location, nsText.length)
            let currentLineRange = nsText.lineRange(for: NSRange(location: safeLocENTER, length: 0))
            let currentLine = nsText.substring(with: currentLineRange).trimmingCharacters(in: .whitespacesAndNewlines)

            // Horizontal rules render via the styler; source stays literal `---` so files round-trip.

            if currentLine.range(of: "^```\\w*$", options: .regularExpression) != nil {
                // Non-overlapping ``` count before the line (what
                // components(separatedBy:).count-1 computed, without
                // materializing an O(doc) substring array).
                var openingCount = 0
                var searchLocation = 0
                while searchLocation < currentLineRange.location {
                    let found = nsText.range(of: "```", options: [],
                                             range: NSRange(location: searchLocation,
                                                            length: currentLineRange.location - searchLocation))
                    if found.location == NSNotFound { break }
                    openingCount += 1
                    searchLocation = NSMaxRange(found)
                }
                let afterLineStart = currentLineRange.location + currentLineRange.length
                let hasClosingAfter: Bool = {
                    guard afterLineStart < nsText.length else { return false }
                    let after = NSRange(location: afterLineStart, length: nsText.length - afterLineStart)
                    return nsText.range(of: "```", options: [], range: after).location != NSNotFound
                }()
                let lineEnd = currentLineRange.location + max(0, currentLineRange.length - 1)
                let cursorAtLineEnd = affectedCharRange.location >= lineEnd

                if openingCount.isMultiple(of: 2) && cursorAtLineEnd && !hasClosingAfter {
                    let insertionLocation = affectedCharRange.location
                    let completion = "\n\n```"
                    MarkdownLists.performEdit(textView, replace: affectedCharRange, with: completion)
                    textView.setSelectedRange(NSRange(location: insertionLocation + 1, length: 0))
                    return false
                }
            }

            // Skip list / blockquote continuation in code blocks.
            guard listsEnabled && !isInCodeBlock else { return true }

            // Blockquote continuation: `> foo` → `\n> `, `>>>` stays `>>>`, empty marker → exit.
            // Fork: a list item in the quote goes to the list branch, which reads the line from
            // `listStart` and repeats `quotePrefix` (`> - a` → `\n> - `, empty `> - ` → `> `).
            var quotePrefix = ""
            var listStart = 0
            let quoteLine = nsText.substring(with: currentLineRange)
            if let quoteMatch = MarkdownLists.blockquoteRegex.firstMatch(
                in: quoteLine,
                range: NSRange(location: 0, length: quoteLine.utf16.count)
            ) {
                let ws = (quoteLine as NSString).substring(with: quoteMatch.range(at: 1))
                let markers = (quoteLine as NSString).substring(with: quoteMatch.range(at: 2))
                let prefixLength = quoteMatch.range.length
                let contentStart = quoteMatch.range.location + prefixLength
                let contentLength = quoteLine.utf16.count - contentStart
                let contentText = (quoteLine as NSString)
                    .substring(with: NSRange(location: contentStart, length: contentLength))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // The quote's text starts after the last `>` and one space or tab.
                let quotedStart = min(NSMaxRange(quoteMatch.range(at: 2)) + 1, contentStart)

                if MarkdownLists.listRegex.firstMatch(
                    in: quoteLine,
                    range: NSRange(location: quotedStart, length: quoteLine.utf16.count - quotedStart)
                ) != nil {
                    quotePrefix = ws + markers + " "
                    listStart = quotedStart
                } else if contentText.isEmpty {
                    return removeLinePrefixAndExit(
                        textView: textView,
                        currentLineRange: currentLineRange,
                        prefixLength: prefixLength
                    )
                } else {
                    MarkdownLists.performEdit(textView, replace: affectedCharRange, with: "\n" + ws + markers + " ")
                    return false
                }
            }

            let listLine = nsText.substring(with: currentLineRange)
            let listRange = NSRange(location: listStart, length: listLine.utf16.count - listStart)
            if let match = MarkdownLists.listRegex.firstMatch(in: listLine, range: listRange) {
                let contentStart = match.range.location + match.range.length
                let contentLength = listLine.utf16.count - contentStart
                let contentRangeLocal = NSRange(location: contentStart, length: contentLength)
                let contentText = (listLine as NSString).substring(with: contentRangeLocal).trimmingCharacters(in: .whitespacesAndNewlines)
                if contentText.isEmpty {
                    return removeLinePrefixAndExit(
                        textView: textView,
                        currentLineRange: currentLineRange,
                        from: listStart,
                        prefixLength: match.range.location + match.range.length
                    )
                }
                let leadingWhitespace: String
                if let wsMatch = MarkdownLists.leadingWhitespaceRegex.firstMatch(in: listLine, range: listRange) {
                    leadingWhitespace = (listLine as NSString).substring(with: wsMatch.range)
                } else {
                    leadingWhitespace = ""
                }
                let markerRaw = (listLine as NSString).substring(with: match.range(at: 1))
                let marker = markerRaw.trimmingCharacters(in: .whitespaces)
                let hasCheckbox = marker.range(of: TaskMarker.boxPattern, options: .regularExpression) != nil
                let newListItem: String
                if match.range(at: 2).location != NSNotFound,
                   let number = Int((listLine as NSString).substring(with: match.range(at: 2))) {
                    if hasCheckbox {
                        newListItem = "\n" + quotePrefix + leadingWhitespace + "\(number + 1). [ ] "
                    } else {
                        newListItem = "\n" + quotePrefix + leadingWhitespace + "\(number + 1). "
                    }
                } else {
                    // Continue with the user's marker char (legacy `•` → `-`), keeping leading whitespace.
                    let bulletChar = (marker.first == "•") ? "-" : String(marker.prefix(1))
                    if hasCheckbox {
                        newListItem = "\n" + quotePrefix + leadingWhitespace + bulletChar + " [ ] "
                    } else {
                        newListItem = "\n" + quotePrefix + leadingWhitespace + bulletChar + " "
                    }
                }
                MarkdownLists.performEdit(textView, replace: affectedCharRange, with: newListItem)
                return false
            }
        }

        return true
    }
}
