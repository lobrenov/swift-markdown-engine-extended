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

    /// A use of a Markdown link or image whose destination is a relative path: not a URL with a scheme, a `//` one or a
    /// `#fragment` or `?query` alone. The use is inline (`[text](destination)`, `![alt](destination)`) or through a
    /// reference (`[text][ref]`, `[ref]`), when `[ref]: destination` is defined; then `path`, `raw`, `range` and `angle`
    /// are the definition's, and the uses of one definition share its `range`. Autolinks aren't read.
    public struct MarkdownLink: Hashable, Sendable {
        public var line: Int
        /// The destination before any `#` or `?`, backslash escapes resolved and percent-decoded.
        public var path: String
        /// The same as written: escapes and percent-encoding kept.
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
        scanner.facts.markdownLinks = scanner.uses.sorted { ($0.position, $0.order) < ($1.position, $1.order) }.map(\.link)
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

    /// A Markdown link or image the body uses, where it starts. One through a reference points at its definition.
    struct Use {
        var position: Int
        var order: Int
        var link: MarkdownFacts.MarkdownLink
        var viaDefinition: Bool
    }
    var uses: [Use] = []

    /// A relative destination: what a `MarkdownLink` holds but its line.
    private struct Target {
        var path: String
        var raw: String
        var range: NSRange
        var angle: Bool
    }
    /// Reference definitions by normalised label, the first of each; a destination that isn't relative is nil.
    private var definitions: [String: Target?] = [:]
    /// Where each definition is in the body, and from where a paragraph that starts with some goes on.
    private var definitionRanges: [NSRange] = []
    private var paragraphRest: [Int: Int] = [:]
    /// A table cell's scan reads the document's definitions and holds none.
    private var inheritsDefinitions = false

    private init(_ text: String, firstLineIndex: Int, definitions: [String: Target?]) {
        self.init(text, firstLineIndex: firstLineIndex)
        self.definitions = definitions
        inheritsDefinitions = true
    }

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
        let parsed = DocumentAST.parse(text, precomputedBlocks: blocks, registry: Self.registry)
        if !inheritsDefinitions { collectDefinitions(parsed) }
        var previous: BlockNode?
        var afterBlank = false
        for block in parsed {
            defer {
                if case .blank = block { afterBlank = true } else { previous = block; afterBlank = false }
            }
            switch block {
            case .paragraph(let range, var inlines):
                // Definitions at its start aren't its text.
                var region = range
                if let rest = paragraphRest[range.location] {
                    region = NSRange(location: rest, length: NSMaxRange(range) - rest)
                    inlines = region.length > 0 ? InlineParser.parse(ns, range: region, registry: Self.registry) : []
                }
                if region.length == 0 { break }
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
                collect(inlines, region: region)
            case .heading(let level, let range, let markers, let inlines):
                facts.headings.append(.init(line: line(range.location), level: level, text: headingText(range, markers: markers)))
                collect(inlines, region: range)
            case .blockquote(let range, let inlines, let items):
                addCallouts(in: range)
                addTasks(items)
                let tables = addQuotedTables(in: range)
                let skipped = tables + definitionRanges
                collect(inlines.filter { node in !skipped.contains { NSLocationInRange(Self.start(of: node), $0) } },
                        region: range, excluding: skipped)
            case .list(_, let items):
                addTasks(items)
                for item in items where !isDefinition(item.contentRange) { collect(item.inlines, region: item.contentRange) }
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
                var cellScanner = FactScanner(text, firstLineIndex: rowLine, definitions: definitions)
                cellScanner.scan()
                let cell = cellScanner.facts
                guard column < sources.count else { continue }
                let toSource = sourceOffsets(of: text, in: sources[column])
                func mapped(_ range: NSRange) -> NSRange {
                    let start = toSource[range.location]
                    return NSRange(location: start, length: toSource[NSMaxRange(range) - 1] + 1 - start)
                }
                // A `<br>` in the cell is one source line, so a fact's line is the mapped range's.
                facts.links += cell.links.map { var link = $0; link.range = mapped(link.range); link.line = line(link.range.location); return link }
                facts.embeds += cell.embeds.map { var embed = $0; embed.range = mapped(embed.range); embed.line = line(embed.range.location); return embed }
                for use in cellScanner.uses {
                    var use = use
                    let position = mapped(NSRange(location: use.position, length: 1)).location
                    use.position = position
                    use.link.line = line(position)
                    if !use.viaDefinition {
                        use.link.range = mapped(use.link.range)
                        use.link.raw = string(use.link.range)
                    }
                    uses.append(use)
                }
                facts.tags += cell.tags.map { var tag = $0; tag.line = rowLine; return tag }
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

    /// `region` is the text `nodes` were parsed from: where a reference link is looked for, outside `excluding`.
    private mutating func collect(_ nodes: [InlineNode], region: NSRange? = nil, excluding: [NSRange] = []) {
        if let region { addReferenceUses(nodes, region: region, excluding: excluding) }
        for node in nodes {
            switch node {
            case .wikiLink(let range, _, _, let markers):
                if let parts = WikiLinkParts(inner: innerText(markers)) {
                    facts.links.append(.init(line: line(markers[0].location), parts: parts, range: range))
                }
            case .imageEmbed(let range, _, let markers):
                let pieces = innerText(markers).split(separator: "|", omittingEmptySubsequences: false)
                // A `\|` splits too, its backslash gone.
                if let parts = WikiLinkParts(inner: String(pieces.count > 1 && pieces[0].last == "\\" ? pieces[0].dropLast() : pieces[0])) {
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
        guard markers.count == 4,
              let destination = InlineParser.linkDestination(ns, from: url.location, end: NSMaxRange(url)),
              let target = Self.target(of: destination, in: ns) else { return }
        uses.append(Use(position: markers[0].location, order: uses.count,
                        link: .init(line: line(markers[0].location), path: target.path, raw: target.raw,
                                    range: target.range, angle: target.angle),
                        viaDefinition: false))
    }

    /// The relative path in a destination, as `MarkdownLink` has it. Its ranges are in `text` plus `shift`.
    private static func target(of destination: (range: NSRange, angle: Bool, next: Int), in text: NSString, shift: Int = 0) -> Target? {
        // The path ends at the first `#` or `?`, an escaped one too; its backslash escapes are resolved.
        var path: [unichar] = []
        var pathEnd: Int?
        var cursor = destination.range.location
        let end = NSMaxRange(destination.range)
        while cursor < end {
            let written = cursor
            var c = text.character(at: cursor)
            if c == 0x5C, cursor + 1 < end, InlineParser.isAsciiPunctuationChar(text.character(at: cursor + 1)) {
                cursor += 1
                c = text.character(at: cursor)
            }
            if pathEnd == nil { if c == 0x23 || c == 0x3F { pathEnd = written } else { path.append(c) } }
            cursor += 1
        }
        let range = NSRange(location: destination.range.location, length: (pathEnd ?? end) - destination.range.location)
        guard range.length > 0 else { return nil }
        let unescaped = String(utf16CodeUnits: path, count: path.count)
        guard absolute.firstMatch(in: unescaped, range: NSRange(location: 0, length: path.count)) == nil else { return nil }
        return Target(path: unescaped.removingPercentEncoding ?? unescaped, raw: text.substring(with: range),
                      range: NSRange(location: range.location + shift, length: range.length), angle: destination.angle)
    }

    // MARK: - Reference links

    private func isDefinition(_ range: NSRange) -> Bool {
        definitionRanges.contains { NSLocationInRange(range.location, $0) }
    }

    /// A label as CommonMark matches it: case-folded, with whitespace runs collapsed and trimmed.
    private static func normalised(_ label: String) -> String {
        label.split(whereSeparator: \.isWhitespace).joined(separator: " ").folding(options: .caseInsensitive, locale: nil)
    }

    /// The definitions that start a paragraph: a top-level one, a list item's, a quote's or a quoted item's. A
    /// paragraph that continues a list item or a quote (lazy) doesn't start one.
    private mutating func collectDefinitions(_ blocks: [BlockNode]) {
        var previous: BlockNode?
        var afterBlank = false
        for block in blocks {
            defer {
                if case .blank = block { afterBlank = true } else { previous = block; afterBlank = false }
            }
            switch block {
            case .paragraph(let range, _):
                var lazy = false
                switch (previous, afterBlank) {
                case (.blockquote, false), (.list, false): lazy = true
                default: break
                }
                if !lazy { addDefinitions(in: lines(of: range), startsParagraph: range.location) }
            case .blockquote(let range, _, let items):
                var run: [NSRange] = []
                var level = 0
                func flush(_ me: inout FactScanner) {
                    if !run.isEmpty { me.addDefinitions(in: run, startsParagraph: nil) }
                    run = []
                }
                for line in QuoteLine.lines(in: range, of: ns) {
                    let blank = string(line.content).trimmingCharacters(in: .whitespaces).isEmpty
                    if blank || line.level != level { flush(&self) }
                    if !blank { run.append(line.content); level = line.level }
                }
                flush(&self)
                for item in items { addDefinitions(in: [item.contentRange], startsParagraph: nil) }
            case .list(_, let items):
                for item in items { addDefinitions(in: [item.contentRange], startsParagraph: nil) }
            default:
                break
            }
        }
    }

    /// The lines of `range` without their line breaks.
    private func lines(of range: NSRange) -> [NSRange] {
        var out: [NSRange] = []
        var start = range.location
        while start < NSMaxRange(range) {
            let line = NSIntersectionRange(ns.lineRange(for: NSRange(location: start, length: 0)), range)
            var end = NSMaxRange(line)
            while end > line.location, isLineBreak(ns.character(at: end - 1)) { end -= 1 }
            out.append(NSRange(location: line.location, length: end - line.location))
            start = NSMaxRange(line)
        }
        return out
    }

    /// Reads the definitions at the start of `lines`, a paragraph's lines. `startsParagraph` is the paragraph's
    /// location when what follows the last one is its text.
    private mutating func addDefinitions(in lines: [NSRange], startsParagraph: Int?) {
        guard !lines.isEmpty else { return }
        // The lines joined by `\n`, and where each starts in the body.
        let joined = lines.map(string).joined(separator: "\n") as NSString
        var starts: [Int] = []
        var offset = 0
        for line in lines { starts.append(offset); offset += line.length + 1 }
        func source(_ virtual: Int) -> Int {
            var low = 0, high = starts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if starts[mid] <= virtual { low = mid } else { high = mid - 1 }
            }
            return lines[low].location + virtual - starts[low]
        }
        var at = 0
        var lastEnd: Int?
        while at < joined.length, let found = Self.definition(in: joined, at: at) {
            let label = Self.normalised(joined.substring(with: found.label))
            if definitions[label] == nil {
                let shift = source(found.destination.range.location) - found.destination.range.location
                definitions[label] = .some(Self.target(of: found.destination, in: joined, shift: shift))
            }
            let range = NSRange(location: source(at), length: source(max(at, found.end - 1)) + 1 - source(at))
            definitionRanges.append(range)
            lastEnd = NSMaxRange(range)
            at = found.end
        }
        if let startsParagraph, let lastEnd {
            // The paragraph goes on from the next line: the definition's range ends with its line break, or at the end.
            var rest = lastEnd
            if rest > 0, isLineBreak(ns.character(at: rest - 1)) {
                if ns.character(at: rest - 1) == 0x0D, rest < ns.length, ns.character(at: rest) == 0x0A { rest += 1 }
            } else {
                rest = NSMaxRange(ns.lineRange(for: NSRange(location: min(rest, ns.length - 1), length: 0)))
            }
            paragraphRest[startsParagraph] = rest
        }
    }

    /// A definition (`[label]: destination "title"`) at `start`, a line's start in `text`: its label's range, its
    /// destination, and where it ends: after the line its last part is on.
    private static func definition(in text: NSString, at start: Int)
        -> (label: NSRange, destination: (range: NSRange, angle: Bool, next: Int), end: Int)? {
        let length = text.length
        func isBlank(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }
        func lineEnd(from i: Int) -> Int {
            var j = i
            while j < length, text.character(at: j) != 0x0A { j += 1 }
            return j
        }
        func onlyBlanks(_ from: Int, _ to: Int) -> Bool {
            (from..<to).allSatisfy { isBlank(text.character(at: $0)) }
        }
        var k = start
        while k < length, k - start < 3, text.character(at: k) == 0x20 { k += 1 }
        guard k < length, text.character(at: k) == 0x5B else { return nil }
        var j = k + 1
        let labelStart = j
        while j < length {
            let c = text.character(at: j)
            if c == 0x5C, j + 1 < length { j += 2; continue }
            if c == 0x5B { return nil }
            if c == 0x5D { break }
            j += 1
        }
        guard j < length, j - labelStart <= 999, j + 1 < length, text.character(at: j + 1) == 0x3A,
              !text.substring(with: NSRange(location: labelStart, length: j - labelStart)).allSatisfy(\.isWhitespace)
        else { return nil }
        // Blanks, with one line ending at most, then the destination.
        var m = j + 2
        while m < length, isBlank(text.character(at: m)) { m += 1 }
        if m < length, text.character(at: m) == 0x0A {
            m += 1
            while m < length, isBlank(text.character(at: m)) { m += 1 }
        }
        guard m < length, let destination = InlineParser.linkDestination(text, from: m, end: length) else { return nil }
        let destinationLineEnd = lineEnd(from: destination.next)
        // A title follows after a blank, on the same line or the next, and ends its line.
        var t = destination.next
        while t < length, isBlank(text.character(at: t)) { t += 1 }
        if t > destination.next, t < length, text.character(at: t) == 0x0A {
            t += 1
            while t < length, isBlank(text.character(at: t)) { t += 1 }
        }
        if t > destination.next, t < length, [0x22, 0x27, 0x28].contains(text.character(at: t)) {
            let closer: unichar = text.character(at: t) == 0x28 ? 0x29 : text.character(at: t)
            var q = t + 1
            while q < length, text.character(at: q) != closer {
                if text.character(at: q) == 0x5C { q += 1 }
                else if closer == 0x29, text.character(at: q) == 0x28 { break }
                q += 1
            }
            if q < length, text.character(at: q) == closer {
                let end = lineEnd(from: q + 1)
                if onlyBlanks(q + 1, end) {
                    return (NSRange(location: labelStart, length: j - labelStart), destination, min(end + 1, length))
                }
            }
        }
        guard onlyBlanks(destination.next, destinationLineEnd) else { return nil }
        return (NSRange(location: labelStart, length: j - labelStart), destination, min(destinationLineEnd + 1, length))
    }

    /// Adds each `[text][label]`, `[text][]` and `[label]` in `region` (and its image forms) whose label a definition
    /// has. What is opaque to them is what the inline nodes hold other than text, `excluding` and the definitions.
    private mutating func addReferenceUses(_ nodes: [InlineNode], region: NSRange, excluding: [NSRange]) {
        guard !definitions.isEmpty, region.length > 0 else { return }
        var opaque = (excluding + definitionRanges).filter { NSIntersectionRange($0, region).length > 0 }
        var inlineLinks: [NSRange] = []
        func walk(_ nodes: [InlineNode]) {
            for node in nodes {
                switch node {
                case .code(let range, _), .escape(let range, _, _), .wikiLink(let range, _, _, _), .imageEmbed(let range, _, _),
                     .inlineLatex(let range, _, _), .tag(let range, _), .image(let range, _, _, _):
                    opaque.append(range)
                case .link(let range, _, _, let markers, let children):
                    if markers.count == 4 {
                        // The text is read for references (a badge's image); the brackets and destination aren't.
                        inlineLinks.append(range)
                        opaque.append(markers[0])
                        opaque.append(NSRange(location: markers[1].location, length: NSMaxRange(range) - markers[1].location))
                        walk(children)
                    } else {
                        opaque.append(range)
                    }
                case .emphasis(_, _, _, let children):
                    walk(children)
                case .ext(let node):
                    if node.children.isEmpty { opaque.append(node.range) } else { walk(node.children) }
                case .text:
                    break
                }
            }
        }
        walk(nodes)
        // Sorted and merged, so a position is looked up by bisection.
        opaque.sort { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in opaque {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        func isOpaque(_ i: Int) -> Bool {
            var low = 0, high = merged.count - 1
            while low <= high {
                let mid = (low + high) / 2
                if i < merged[mid].location { high = mid - 1 } else if i >= NSMaxRange(merged[mid]) { low = mid + 1 } else { return true }
            }
            return false
        }
        // Brackets pair as CommonMark pairs them, innermost first.
        var open: [Int] = []
        var pairs: [(open: Int, close: Int)] = []
        var closeOf: [Int: Int] = [:]
        for i in region.location..<NSMaxRange(region) {
            let c = ns.character(at: i)
            guard c == 0x5B || c == 0x5D, !isOpaque(i) else { continue }
            if c == 0x5B { open.append(i) } else if let start = open.popLast() {
                pairs.append((start, i))
                closeOf[start] = i
            }
        }
        func hasBracket(_ from: Int, _ to: Int) -> Bool {
            (from..<to).contains { (ns.character(at: $0) == 0x5B || ns.character(at: $0) == 0x5D) && !isOpaque($0) }
        }
        var consumed: Set<Int> = []
        var resolved: [NSRange] = []
        for (start, close) in pairs where !consumed.contains(start) {
            var label: NSRange?
            var end = close
            let next = close + 1
            if next < NSMaxRange(region), ns.character(at: next) == 0x5B, let labelClose = closeOf[next] {
                let written = NSRange(location: next + 1, length: labelClose - next - 1)
                if written.length == 0, !hasBracket(start + 1, close) {
                    label = NSRange(location: start + 1, length: close - start - 1)   // collapsed
                    end = labelClose
                } else if !string(written).allSatisfy(\.isWhitespace), !hasBracket(written.location, NSMaxRange(written)) {
                    label = written   // full
                    end = labelClose
                } else if !hasBracket(start + 1, close) {
                    label = NSRange(location: start + 1, length: close - start - 1)
                }
            } else if !hasBracket(start + 1, close) {
                label = NSRange(location: start + 1, length: close - start - 1)   // shortcut
            }
            guard let label, !string(label).allSatisfy(\.isWhitespace), label.length <= 999,
                  let definition = definitions[Self.normalised(string(label))] else { continue }
            let isImage = start > region.location && ns.character(at: start - 1) == 0x21 && !isOpaque(start - 1)
            let whole = NSRange(location: start, length: end + 1 - start)
            // A link holds no link.
            if !isImage, (inlineLinks + resolved).contains(where: { NSIntersectionRange($0, whole).length > 0 && $0.location > start }) { continue }
            if end != close { consumed.insert(close + 1) }
            if !isImage { resolved.append(whole) }
            if let target = definition {
                let position = isImage ? start - 1 : start
                uses.append(Use(position: position, order: uses.count,
                                link: .init(line: line(position), path: target.path, raw: target.raw, range: target.range, angle: target.angle),
                                viaDefinition: true))
            }
        }
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
