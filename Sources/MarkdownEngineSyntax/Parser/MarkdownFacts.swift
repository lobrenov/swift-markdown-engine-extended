//
//  MarkdownFacts.swift
//  MarkdownEngineSyntax
//
//  Fork: what a markdown body holds — summary, headings, tasks, links, embeds, tags, callouts and tables — read
//  with the editor's own block and inline parsers. `spec/grammar` states the facts each case yields.
//

import Foundation

public struct MarkdownFacts: Equatable, Sendable {
    public struct Heading: Equatable, Sendable {
        public var line: Int
        public var level: Int
        /// As written, without the `#` markers or a closing `#` run.
        public var text: String
    }

    public struct Task: Equatable, Sendable {
        public var line: Int
        public var marker: Character
        /// After the box, trimmed.
        public var text: String
    }

    public struct Link: Equatable, Sendable {
        public var line: Int
        public var parts: WikiLinkParts
    }

    public struct Embed: Equatable, Sendable {
        public var line: Int
        public var target: String
        public var heading: String?
        public var block: String?
        /// The `|`-separated parts after the target, as written.
        public var segments: [String]
    }

    public struct Tag: Equatable, Sendable {
        public var line: Int
        /// Without `#`.
        public var name: String
    }

    public struct Callout: Equatable, Sendable {
        public enum Fold: Sendable { case open, folded }
        /// As written, lowercased.
        public var type: String
        public var fold: Fold?
        public var title: String?
        public var startLine: Int
        public var endLine: Int
    }

    public struct Table: Equatable, Sendable {
        public var startLine: Int
        public var endLine: Int
        public var columns: Int
    }

    /// The first top-level paragraph's text, without inline markup.
    public var summary: String?
    public var headings: [Heading] = []
    public var tasks: [Task] = []
    public var links: [Link] = []
    public var embeds: [Embed] = []
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
    private static let registry = ExtensionRegistry(syntax: [], tags: true)

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
        var starts = [0]
        for i in 0..<ns.length where ns.character(at: i) == 0x0A { starts.append(i + 1) }
        lineStarts = starts
    }

    mutating func scan() {
        for block in DocumentAST.parse(text, registry: Self.registry) {
            switch block {
            case .paragraph(_, let inlines):
                if facts.summary == nil { facts.summary = plainText(inlines) }
                collect(inlines)
            case .heading(let level, let range, _, let inlines):
                facts.headings.append(.init(line: line(range.location), level: level, text: headingText(range)))
                collect(inlines)
            case .blockquote(let range, let inlines, let items):
                addCallouts(in: range)
                addTasks(items)
                collect(inlines)
            case .list(_, let items):
                addTasks(items)
                for item in items { collect(item.inlines) }
            case .table(let range):
                addTable(range)
            case .codeBlock, .blockLatex, .thematicBreak, .blank, .ext:
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

    private func headingText(_ range: NSRange) -> String {
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
            guard let marker = item.taskMarker else { continue }
            let text = string(item.contentRange).trimmingCharacters(in: .whitespacesAndNewlines)
            facts.tasks.append(.init(line: line(item.range.location), marker: marker, text: text))
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

    private mutating func addTable(_ range: NSRange) {
        let source = string(range)
        let trimmed = source.hasSuffix("\n") ? String(source.dropLast()) : source
        guard let table = MarkdownTable.parse(trimmed) else { return }
        let startLine = line(range.location)
        facts.tables.append(.init(startLine: startLine, endLine: line(range.location + (trimmed as NSString).length),
                                  columns: table.columnCount))
        // Each cell is read as a paragraph of its own, unescaped as the editor draws it (`\|` is a link's alias bar).
        for row in 0..<table.rowCount {
            let rowLine = startLine + (row == 0 ? 0 : row + 1)
            for column in 0..<table.columnCount {
                let cell = MarkdownFacts.scan(table.cell(row: row, column: column), firstLineIndex: rowLine)
                facts.links += cell.links
                facts.embeds += cell.embeds
                facts.tags += cell.tags
            }
        }
    }

    // MARK: - Inlines

    private mutating func collect(_ nodes: [InlineNode]) {
        for node in nodes {
            switch node {
            case .wikiLink(_, _, _, let markers):
                if let parts = WikiLinkParts(inner: innerText(markers)) {
                    facts.links.append(.init(line: line(markers[0].location), parts: parts))
                }
            case .imageEmbed(_, _, let markers):
                let pieces = innerText(markers).split(separator: "|", omittingEmptySubsequences: false)
                if let parts = WikiLinkParts(inner: String(pieces[0])) {
                    facts.embeds.append(.init(line: line(markers[0].location), target: parts.target,
                                              heading: parts.heading, block: parts.block,
                                              segments: pieces.dropFirst().map(String.init)))
                }
            case .tag(let range, let marker):
                let name = NSRange(location: NSMaxRange(marker), length: NSMaxRange(range) - NSMaxRange(marker))
                facts.tags.append(.init(line: line(range.location), name: string(name)))
            case .emphasis(_, _, _, let children), .link(_, _, _, _, let children):
                collect(children)
            case .ext(let node):
                collect(node.children)
            case .text, .code, .image, .inlineLatex, .escape:
                break
            }
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
                case .text(let range), .wikiLink(let range, _, _, _), .imageEmbed(let range, _, _),
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
}
