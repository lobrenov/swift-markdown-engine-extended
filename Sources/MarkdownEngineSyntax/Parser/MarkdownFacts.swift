//
//  MarkdownFacts.swift
//  MarkdownEngineSyntax
//
//  Fork: what a markdown body holds — summary, headings, tasks, links, embeds, Markdown links, tags, callouts and tables — read
//  with the editor's own block and inline parsers. `spec/grammar` states the facts each case yields.
//

import Foundation

public struct MarkdownFacts: Hashable, Sendable {
    public struct Heading: Hashable, Sendable {
        public var line: Int
        public var level: Int
        /// As written, without the `#` markers or a closing `#` run.
        public var text: String
    }

    public struct TaskItem: Hashable, Sendable {
        public var line: Int
        public var marker: Character
        /// The rest of the item's first line, trimmed, as written.
        public var text: String
        /// Where `[c]` is in the body (UTF-16).
        public var box: NSRange
    }

    public struct Link: Hashable, Sendable {
        public var line: Int
        public var parts: WikiLinkParts
        /// Where `[[…]]` is in the body (UTF-16).
        public var range: NSRange
    }

    public struct Embed: Hashable, Sendable {
        public var line: Int
        public var target: String
        public var heading: String?
        public var block: String?
        /// The `|`-separated parts after the target, as written.
        public var segments: [String]
        /// Where `![[…]]` is in the body (UTF-16).
        public var range: NSRange
    }

    /// An inline `[text](destination)` or `![alt](destination)` whose destination is a relative path: not a
    /// URL with a scheme, a `//` one or a `#fragment` or `?query` alone. Reference links and autolinks aren't read.
    public struct MarkdownLink: Hashable, Sendable {
        public var line: Int
        /// The destination before any `#` or `?`, percent-decoded.
        public var path: String
        /// The same as written, still percent-encoded.
        public var raw: String
        /// Where `raw` is in the body (UTF-16).
        public var range: NSRange
        /// The destination is written between `<` and `>`.
        public var angle: Bool
    }

    public struct Tag: Hashable, Sendable {
        public var line: Int
        /// Without `#`.
        public var name: String
    }

    public struct Callout: Hashable, Sendable {
        public enum Fold: Sendable { case open, folded }
        /// As written, lowercased.
        public var type: String
        public var fold: Fold?
        public var title: String?
        public var startLine: Int
        public var endLine: Int
    }

    public struct Table: Hashable, Sendable {
        public var startLine: Int
        public var endLine: Int
        public var columns: Int
    }

    /// The first top-level paragraph's text, without inline markup. A list item's or quote's continuation
    /// lines aren't top-level.
    public var summary: String?
    public var headings: [Heading] = []
    public var tasks: [TaskItem] = []
    public var links: [Link] = []
    public var embeds: [Embed] = []
    public var markdownLinks: [MarkdownLink] = []
    public var tags: [Tag] = []
    public var callouts: [Callout] = []
    public var tables: [Table] = []

    /// Reads `body` (no frontmatter); its first line is line `firstLineIndex`.
    public static func scan(_ body: String, firstLineIndex: Int = 0) -> MarkdownFacts {
        var scanner = FactScanner(body, firstLineIndex: firstLineIndex)
        scanner.scan()
        return scanner.facts
    }
}

private struct FactScanner {
    /// Tags, GFM strikethrough and Obsidian highlight.
    private static let registry = ExtensionRegistry(syntax: [
        (id: "strikethrough", inline: InlineSyntax(open: "~~", close: "~~", rejectsCloserRun: true), block: nil),
        (id: "highlight", inline: InlineSyntax(open: "==", close: "=="), block: nil),
    ], tags: true)

    private let text: String
    private let ns: NSString
    private let firstLineIndex: Int
    /// UTF-16 offset where each line starts.
    private let lineStarts: [Int]
    var facts = MarkdownFacts()

    init(_ text: String, firstLineIndex: Int) {
        self.text = text
        ns = text as NSString
        self.firstLineIndex = firstLineIndex
        // Lines as the block parser splits them (`\n`, `\r\n`, `\r`, U+2028…).
        var starts = [0]
        var cursor = 0
        while cursor < ns.length {
            cursor = NSMaxRange(ns.lineRange(for: NSRange(location: cursor, length: 0)))
            if cursor < ns.length { starts.append(cursor) }
        }
        lineStarts = starts
    }

    mutating func scan() {
        // Its own block parse: the parser's memo belongs to the editor.
        let blocks = BlockParser.computeBlocks(text, registry: Self.registry)
        var previous: BlockNode?
        var afterBlank = false
        for block in DocumentAST.parse(text, precomputedBlocks: blocks, registry: Self.registry) {
            defer {
                if case .blank = block { afterBlank = true } else { previous = block; afterBlank = false }
            }
            switch block {
            case .paragraph(let range, let inlines):
                switch (previous, afterBlank) {
                case (.blockquote(let quote, _, _), false):
                    // A lazy line continues the quote and the callouts that reached its end.
                    let quoteEnd = lastLine(of: quote)
                    for i in facts.callouts.indices where facts.callouts[i].endLine == quoteEnd {
                        facts.callouts[i].endLine = lastLine(of: range)
                    }
                case (.list, false):
                    break   // a lazy line of the last item
                case (.list, true) where isIndented(range):
                    break   // a later paragraph of the last item
                default:
                    if facts.summary == nil { facts.summary = plainText(inlines) }
                }
                collect(inlines)
            case .heading(let level, let range, let markers, let inlines):
                facts.headings.append(.init(line: line(range.location), level: level, text: headingText(range, markers: markers)))
                collect(inlines)
            case .blockquote(let range, let inlines, let items):
                addCallouts(in: range)
                addTasks(items)
                let tables = addQuotedTables(in: range)
                collect(inlines.filter { node in !tables.contains { NSLocationInRange(Self.start(of: node), $0) } })
            case .list(_, let items):
                addTasks(items)
                for item in items { collect(item.inlines) }
            case .table(let range):
                var rows: [NSRange] = []
                var start = range.location
                while start < NSMaxRange(range) {
                    let line = ns.lineRange(for: NSRange(location: start, length: 0))
                    var end = NSMaxRange(line)
                    while end > line.location, isLineBreak(ns.character(at: end - 1)) { end -= 1 }
                    if !string(NSRange(location: line.location, length: end - line.location)).trimmingCharacters(in: .whitespaces).isEmpty {
                        rows.append(NSRange(location: line.location, length: end - line.location))
                    }
                    start = NSMaxRange(line)
                }
                addTable(rows: rows)
            case .codeBlock, .indentedCode, .html, .blockLatex, .thematicBreak, .blank, .ext:
                break
            }
        }
    }

    // MARK: - Blocks

    private func line(_ location: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return firstLineIndex + low
    }

    private func string(_ range: NSRange) -> String { ns.substring(with: range) }

    /// The line `range` ends on, its line break aside.
    private func lastLine(of range: NSRange) -> Int {
        var end = NSMaxRange(range)
        while end > range.location, isLineBreak(ns.character(at: end - 1)) { end -= 1 }
        return line(max(range.location, end - 1))
    }

    private func isLineBreak(_ c: unichar) -> Bool {
        c == 0x0A || c == 0x0D || c == 0x2028 || c == 0x2029 || c == 0x85
    }

    /// Whether `range` starts with 2 or more columns of indent (an item's content column).
    private func isIndented(_ range: NSRange) -> Bool {
        guard range.length > 0 else { return false }
        let c = ns.character(at: range.location)
        return c == 0x09 || (c == 0x20 && range.length > 1 && [0x20, 0x09].contains(ns.character(at: range.location + 1)))
    }

    private func headingText(_ range: NSRange, markers: [NSRange]) -> String {
        // A setext heading's marker is its underline line; its text is the lines above, joined.
        if let underline = markers.first, line(underline.location) > line(range.location) {
            return string(NSRange(location: range.location, length: underline.location - range.location))
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
        }
        var s = Substring(string(range)).trimmingCharacters(in: .whitespacesAndNewlines)[...]
        s = s.drop { $0 == "#" }
        s = s.drop { $0 == " " || $0 == "\t" }
        // A closing run of `#`s after a space, or the whole content.
        let withoutRun = s.reversed().drop { $0 == "#" }
        if withoutRun.isEmpty {
            s = ""
        } else if let last = withoutRun.first, last == " " || last == "\t", withoutRun.count < s.count {
            s = s.prefix(withoutRun.count)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private mutating func addTasks(_ items: [ListItem]) {
        for item in items {
            guard let marker = item.taskMarker, let box = item.checkbox else { continue }
            let text = string(item.contentRange).trimmingCharacters(in: .whitespacesAndNewlines)
            facts.tasks.append(.init(line: line(item.range.location), marker: marker, text: text, box: box))
        }
    }

    private mutating func addCallouts(in range: NSRange) {
        let lines = QuoteLine.lines(in: range, of: ns)
        for callout in MarkdownEngineSyntax.Callout.find(in: lines, of: ns) {
            let header = callout.header
            let fold: MarkdownFacts.Callout.Fold? = switch header.fold.length == 0 ? "" : string(header.fold) {
            case "+": .open
            case "-": .folded
            default: nil
            }
            facts.callouts.append(.init(
                type: string(header.type).lowercased(), fold: fold,
                title: header.title.length == 0 ? nil : string(header.title),
                startLine: line(lines[callout.first].line.location), endLine: line(lines[callout.last].line.location)))
        }
    }

    /// A table's lines, without their line breaks (and quote markers): the header, the delimiter row, the body rows.
    private mutating func addTable(rows: [NSRange]) {
        guard let table = MarkdownTable.parse(rows.map(string).joined(separator: "\n")), table.rowCount + 1 == rows.count
        else { return }
        let startLine = line(rows[0].location)
        facts.tables.append(.init(startLine: startLine, endLine: line(rows[rows.count - 1].location), columns: table.columnCount))
        // Each cell is read as a paragraph of its own, unescaped as the editor draws it (`\|` is a link's alias bar).
        for row in 0..<table.rowCount {
            let source = rows[row == 0 ? 0 : row + 1]
            let rowLine = line(source.location)
            let sources = cellSources(source)
            for column in 0..<table.columnCount {
                let text = table.cell(row: row, column: column)
                let cell = MarkdownFacts.scan(text, firstLineIndex: rowLine)
                guard column < sources.count else { continue }
                let toSource = sourceOffsets(of: text, in: sources[column])
                func mapped(_ range: NSRange) -> NSRange {
                    let start = toSource[range.location]
                    return NSRange(location: start, length: toSource[NSMaxRange(range) - 1] + 1 - start)
                }
                facts.links += cell.links.map { var link = $0; link.range = mapped(link.range); return link }
                facts.embeds += cell.embeds.map { var embed = $0; embed.range = mapped(embed.range); return embed }
                facts.markdownLinks += cell.markdownLinks.map {
                    var link = $0
                    link.range = mapped(link.range)
                    link.raw = string(link.range)
                    return link
                }
                facts.tags += cell.tags
            }
        }
    }

    /// The tables in a quote's content (a header row, then a delimiter row, then rows), added as tables are.
    /// Returns the lines they cover.
    private mutating func addQuotedTables(in range: NSRange) -> [NSRange] {
        let lines = QuoteLine.lines(in: range, of: ns)
        var covered: [NSRange] = []
        var i = 0
        while i + 1 < lines.count {
            let header = string(lines[i].content)
            guard lines[i + 1].level == lines[i].level, BlockParser.isTableRow(header),
                  BlockParser.isTableSeparator(string(lines[i + 1].content), header: header) else { i += 1; continue }
            var end = i + 2
            while end < lines.count, lines[end].level == lines[i].level, BlockParser.isTableRow(string(lines[end].content)) { end += 1 }
            addTable(rows: lines[i..<end].map(\.content))
            covered.append(NSUnionRange(lines[i].line, lines[end - 1].line))
            i = end
        }
        return covered
    }

    /// Each cell's source in a table row, trimmed, split on the `|`s `MarkdownTable` splits on.
    private func cellSources(_ row: NSRange) -> [NSRange] {
        func isSpace(_ i: Int) -> Bool { UnicodeScalar(ns.character(at: i)).map(CharacterSet.whitespaces.contains) ?? false }
        var end = NSMaxRange(row)
        var from = row.location
        while from < end, isSpace(from) { from += 1 }
        while end > from, isSpace(end - 1) { end -= 1 }
        func backslashes(before i: Int) -> Int {
            var j = i
            while j > from, ns.character(at: j - 1) == 0x5C { j -= 1 }
            return i - j
        }
        if from < end, ns.character(at: from) == 0x7C { from += 1 }
        if end > from, ns.character(at: end - 1) == 0x7C, backslashes(before: end - 1) % 2 == 0 { end -= 1 }
        var cells: [NSRange] = []
        var cellStart = from
        for i in from...end where i == end || (ns.character(at: i) == 0x7C && backslashes(before: i) % 2 == 0) {
            var (a, b) = (cellStart, i)
            while a < b, isSpace(a) { a += 1 }
            while b > a, isSpace(b - 1) { b -= 1 }
            cells.append(NSRange(location: a, length: b - a))
            cellStart = i + 1
        }
        return cells
    }

    /// For each UTF-16 offset in a cell's text, the offset in `source` it was read from: `MarkdownTable` drops
    /// backslashes and reads `<br>` as a line break.
    private func sourceOffsets(of text: String, in source: NSRange) -> [Int] {
        let cell = text as NSString
        var offsets: [Int] = []
        var i = source.location
        let end = NSMaxRange(source)
        for j in 0..<cell.length {
            let c = cell.character(at: j)
            while i < end, ns.character(at: i) != c, !(c == 0x0A && ns.character(at: i) == 0x3C) { i += 1 }
            offsets.append(min(i, end))
            if c == 0x0A { while i < end, ns.character(at: i) != 0x3E { i += 1 } }
            i += 1
        }
        return offsets
    }

    // MARK: - Inlines

    private mutating func collect(_ nodes: [InlineNode]) {
        for node in nodes {
            switch node {
            case .wikiLink(let range, _, _, let markers):
                if let parts = WikiLinkParts(inner: innerText(markers)) {
                    facts.links.append(.init(line: line(markers[0].location), parts: parts, range: range))
                }
            case .imageEmbed(let range, _, let markers):
                let pieces = innerText(markers).split(separator: "|", omittingEmptySubsequences: false)
                if let parts = WikiLinkParts(inner: String(pieces[0])) {
                    facts.embeds.append(.init(line: line(markers[0].location), target: parts.target,
                                              heading: parts.heading, block: parts.block,
                                              segments: pieces.dropFirst().map(String.init), range: range))
                }
            case .tag(let range, let marker):
                let name = NSRange(location: NSMaxRange(marker), length: NSMaxRange(range) - NSMaxRange(marker))
                facts.tags.append(.init(line: line(range.location), name: string(name)))
            case .link(_, _, let url, let markers, let children):
                addMarkdownLink(url: url, markers: markers)
                collect(children)
            case .image(_, _, let url, let markers):
                addMarkdownLink(url: url, markers: markers)
            case .emphasis(_, _, _, let children):
                collect(children)
            case .ext(let node):
                collect(node.children)
            case .text, .code, .inlineLatex, .escape:
                break
            }
        }
    }

    // MARK: - Markdown links

    private static let absolute = try! NSRegularExpression(pattern: #"^(?:[A-Za-z][A-Za-z0-9+.\-]*:|//)"#)

    /// Adds the destination in `url` when it's a relative path. An autolink's markers are `<` and `>` only.
    private mutating func addMarkdownLink(url: NSRange, markers: [NSRange]) {
        guard markers.count == 4 else { return }
        func isBlank(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A }
        var cursor = url.location
        let end = NSMaxRange(url)
        while cursor < end, isBlank(ns.character(at: cursor)) { cursor += 1 }
        guard cursor < end else { return }
        let angle = ns.character(at: cursor) == 0x3C
        if angle { cursor += 1 }
        let first = cursor
        // The destination ends at `>` (in `<…>`) or at a space; the path, at its first `#` or `?`.
        var pathEnd: Int?
        var closed = !angle
        while cursor < end {
            let c = ns.character(at: cursor)
            if angle ? c == 0x3E : isBlank(c) {
                closed = true
                break
            }
            if pathEnd == nil, c == 0x23 || c == 0x3F { pathEnd = cursor }
            cursor += 1
        }
        let range = NSRange(location: first, length: (pathEnd ?? cursor) - first)
        guard closed, range.length > 0 else { return }
        let raw = string(range)
        guard Self.absolute.firstMatch(in: raw, range: NSRange(location: 0, length: range.length)) == nil else { return }
        facts.markdownLinks.append(.init(line: line(markers[0].location), path: raw.removingPercentEncoding ?? raw,
                                         raw: raw, range: range, angle: angle))
    }

    private static func start(of node: InlineNode) -> Int {
        switch node {
        case .text(let range), .code(let range, _), .tag(let range, _), .emphasis(_, let range, _, _),
             .link(let range, _, _, _, _), .image(let range, _, _, _), .wikiLink(let range, _, _, _),
             .imageEmbed(let range, _, _), .inlineLatex(let range, _, _), .escape(let range, _, _):
            range.location
        case .ext(let node): node.range.location
        }
    }

    private func innerText(_ markers: [NSRange]) -> String {
        let start = NSMaxRange(markers[0])
        return string(NSRange(location: start, length: markers[1].location - start))
    }

    private func plainText(_ nodes: [InlineNode]) -> String {
        var out = ""
        func walk(_ nodes: [InlineNode]) {
            for node in nodes {
                switch node {
                case .text(let range):
                    out += Self.withoutHTML(string(range))
                case .wikiLink(let range, _, _, _), .imageEmbed(let range, _, _),
                     .tag(let range, _), .inlineLatex(let range, _, _):
                    out += string(range)
                case .code(_, let content): out += string(content)
                case .escape(_, let character, _): out += string(character)
                case .image(_, let alt, _, _): out += string(alt)
                case .emphasis(_, _, _, let children), .link(_, _, _, _, let children): walk(children)
                case .ext(let node): node.children.isEmpty ? (out += string(node.range)) : walk(node.children)
                }
            }
        }
        walk(nodes)
        return out.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - HTML in text

    private static let htmlTag = try! NSRegularExpression(
        pattern: #"<!--.*?-->|</?[A-Za-z][A-Za-z0-9-]*(?:\s[^<>]*)?/?>"#, options: [.dotMatchesLineSeparators])
    private static let entity = try! NSRegularExpression(pattern: #"&(?:#[0-9]{1,7}|#[xX][0-9A-Fa-f]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});"#)
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "copy": "©", "reg": "®",
        "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
    ]

    /// Text with inline HTML tags dropped and character references decoded.
    static func withoutHTML(_ text: String) -> String {
        guard text.contains("<") || text.contains("&") else { return text }
        var s = htmlTag.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                                withTemplate: "")
        let ns = s as NSString
        var out = ""
        var last = 0
        for match in entity.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let body = ns.substring(with: NSRange(location: match.range.location + 1, length: match.range.length - 2))
            var decoded: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                decoded = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map(String.init)
            } else if body.hasPrefix("#") {
                decoded = UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map(String.init)
            } else {
                decoded = namedEntities[body]
            }
            out += decoded ?? ns.substring(with: match.range)
            last = NSMaxRange(match.range)
        }
        out += ns.substring(from: last)
        s = out
        return s
    }
}
