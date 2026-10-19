//
//  MarkdownTableTests.swift
//  MarkdownEngineTests
//
//  Fork: the table model's parse, padded write and edits.
//

import Testing
@testable import MarkdownEngine

@Suite("MarkdownTable")
struct MarkdownTableTests {

    private func table(_ source: String) throws -> MarkdownTable {
        try #require(MarkdownTable.parse(source))
    }

    private let sample = """
    | a   | b   |
    | --- | --- |
    | 1   | 2   |
    | 3   | 4   |
    """

    // MARK: - Round trips

    @Test func paddedTableRoundTripsUnchanged() throws {
        #expect(try table(sample).markdown == sample)
    }

    @Test func columnsPadToTheWidestCell() throws {
        let t = try table("|a|bb|\n|-|-|\n|long cell|x|")
        #expect(t.markdown == "| a         | bb  |\n| --------- | --- |\n| long cell | x   |")
    }

    @Test func leadingAndTrailingPipesAreOptional() throws {
        let t = try table("a | b\n--|--\n1 | 2")
        #expect(t.header == ["a", "b"])
        #expect(t.rows == [["1", "2"]])
        #expect(t.markdown == "| a   | b   |\n| --- | --- |\n| 1   | 2   |")
    }

    @Test func alignmentMarkersAreKept() throws {
        let t = try table("| a | b | c | d |\n|---|:--|:-:|--:|\n| 1 | 2 | 3 | 4 |")
        #expect(t.alignments == [.none, .left, .center, .right])
        #expect(t.markdown == "| a   | b   | c   | d   |\n| --- | :-- | :-: | --: |\n| 1   | 2   | 3   | 4   |")
        #expect(try table(t.markdown) == t)
    }

    @Test func escapedPipesAreUnescapedInCellsAndEscapedOnWrite() throws {
        let t = try table("| a \\| b | c |\n|---|---|\n| `x \\| y` | z |")
        #expect(t.header == ["a | b", "c"])
        #expect(t.rows == [["`x | y`", "z"]])
        #expect(t.markdown.contains("| a \\| b "))
        #expect(try table(t.markdown) == t)
    }

    @Test func brIsALineBreakInTheCell() throws {
        let t = try table("| a | b |\n|---|---|\n| one<br>two | x<BR/>y |")
        #expect(t.rows == [["one\ntwo", "x\ny"]])
        #expect(t.markdown.contains("| one<br>two "))
        #expect(try table(t.markdown) == t)
    }

    @Test func raggedRowsPadAndExtraCellsAreCut() throws {
        let t = try table("| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |")
        #expect(t.rows == [["1", ""], ["1", "2"]])
    }

    @Test func emptyCellsKeepTheirWidth() throws {
        let t = try table("| a | b |\n|---|---|\n|  | x |")
        #expect(t.markdown == "| a   | b   |\n| --- | --- |\n|     | x   |")
        #expect(try table(t.markdown) == t)
    }

    @Test func paddingCountsCharactersNotBytes() throws {
        let t = try table("| é | 日本語 |\n|---|---|\n| ab | c |")
        #expect(t.markdown == "| é   | 日本語 |\n| --- | --- |\n| ab  | c   |")
    }

    @Test func nonTablesDontParse() {
        #expect(MarkdownTable.parse("| a |") == nil)
        #expect(MarkdownTable.parse("") == nil)
    }

    // MARK: - Edits

    @Test func setCellWritesBodyAndHeader() throws {
        var t = try table(sample)
        t.setCell(row: 0, column: 1, to: "H")
        t.setCell(row: 2, column: 0, to: "x\ny|z")
        #expect(t.header == ["a", "H"])
        #expect(t.rows[1] == ["x\ny|z", "4"])
    }

    @Test func insertRowAddsABlankRow() throws {
        var t = try table(sample)
        t.insertRow(at: 1)
        #expect(t.rows == [["", ""], ["1", "2"], ["3", "4"]])
        t.insertRow(at: 4)
        #expect(t.rows.last == ["", ""])
        #expect(t.rowCount == 5)
    }

    @Test func insertingAboveTheHeaderMakesABlankHeader() throws {
        var t = try table(sample)
        t.insertRow(at: 0)
        #expect(t.header == ["", ""])
        #expect(t.rows.first == ["a", "b"])
    }

    @Test func deleteRowRemovesABodyRow() throws {
        var t = try table(sample)
        t.deleteRow(at: 1)
        #expect(t.rows == [["3", "4"]])
        #expect(t.header == ["a", "b"])
    }

    @Test func deletingTheHeaderPromotesTheNextRow() throws {
        var t = try table(sample)
        t.deleteRow(at: 0)
        #expect(t.header == ["1", "2"])
        #expect(t.rows == [["3", "4"]])
    }

    @Test func theOnlyRowCantBeDeletedFromTheModel() throws {
        var t = try table("| a |\n|---|")
        t.deleteRow(at: 0)
        #expect(t.rowCount == 1)
        #expect(t.header == ["a"])
    }

    @Test func moveRowReordersBodyRows() throws {
        var t = try table("| h |\n|---|\n| 1 |\n| 2 |\n| 3 |")
        t.moveRow(from: 3, to: 1)
        #expect(t.rows == [["3"], ["1"], ["2"]])
        t.moveRow(from: 1, to: 3)
        #expect(t.rows == [["1"], ["2"], ["3"]])
    }

    @Test func theHeaderIsFixedAndNothingMovesAboveIt() throws {
        var t = try table("| h |\n|---|\n| 1 |\n| 2 |")
        t.moveRow(from: 0, to: 2)
        #expect(t.header == ["h"])
        #expect(t.rows == [["1"], ["2"]])
        t.moveRow(from: 2, to: 0)
        #expect(t.header == ["h"])
        #expect(t.rows == [["2"], ["1"]])
    }

    @Test func insertColumnAddsABlankColumn() throws {
        var t = try table("| a | b |\n|:-:|--:|\n| 1 | 2 |")
        t.insertColumn(at: 1)
        #expect(t.header == ["a", "", "b"])
        #expect(t.alignments == [.center, .none, .right])
        #expect(t.rows == [["1", "", "2"]])
    }

    @Test func deleteColumnRemovesItsCellsAndAlignment() throws {
        var t = try table("| a | b |\n|:-:|--:|\n| 1 | 2 |")
        t.deleteColumn(at: 0)
        #expect(t.header == ["b"])
        #expect(t.alignments == [.right])
        #expect(t.rows == [["2"]])
        t.deleteColumn(at: 0)
        #expect(t.columnCount == 1)
    }

    @Test func moveColumnCarriesAlignmentAndCells() throws {
        var t = try table("| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 | 3 |")
        t.moveColumn(from: 0, to: 2)
        #expect(t.header == ["b", "c", "a"])
        #expect(t.alignments == [.center, .right, .left])
        #expect(t.rows == [["2", "3", "1"]])
    }

    @Test func setAlignmentChangesTheDelimiterRow() throws {
        var t = try table(sample)
        t.setAlignment(.center, column: 1)
        #expect(t.markdown.split(separator: "\n")[1] == "| --- | :-: |")
        t.setAlignment(.none, column: 1)
        #expect(t.markdown == sample)
    }

    // MARK: - Round trips of awkward cells

    @Test(arguments: ["a\\|b", "a\\", "\\\\", "`x|y`", "a|b", "\\\\|", "x\\\ny", "|", "\\"])
    func anyCellTextRoundTrips(cell: String) throws {
        let t = MarkdownTable(header: ["h", "i"], alignments: [.none, .none], rows: [[cell, "z"], ["q", cell]])
        let parsed = try #require(MarkdownTable.parse(t.markdown))
        #expect(parsed.rows == t.rows)
        #expect(parsed.columnCount == 2)
    }

    @Test func existingEscapedPipesStillRead() throws {
        let t = try table("| a \\| b | c |\n|---|---|\n| x | y |")
        #expect(t.header == ["a | b", "c"])
    }

    @Test func indentationIsKeptOnEveryLine() throws {
        var t = try table("  | a | b |\n  |---|---|\n  | 1 | 2 |")
        #expect(t.indent == "  ")
        #expect(t.markdown == "  | a   | b   |\n  | --- | --- |\n  | 1   | 2   |")
        t.insertRow(at: 2)
        t.insertColumn(at: 1)
        #expect(t.markdown.split(separator: "\n").allSatisfy { $0.hasPrefix("  | ") || $0.hasPrefix("  |") })
    }
}
