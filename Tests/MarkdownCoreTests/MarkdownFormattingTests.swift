import Foundation
import XCTest
@testable import MarkdownCore

final class MarkdownFormattingTests: XCTestCase {
    private func assertResult(
        _ result: MarkdownFormatResult,
        text: String,
        selection: NSRange,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(result.text, text, file: file, line: line)
        XCTAssertEqual(result.selection, selection, file: file, line: line)
        XCTAssertTrue(result.didChange, file: file, line: line)
    }

    // MARK: - Inline styles

    func testBoldWrapsSelection() {
        let result = MarkdownFormatting.toggleInline(.bold, in: "hello world", selection: NSRange(location: 6, length: 5))
        assertResult(result, text: "hello **world**", selection: NSRange(location: 8, length: 5))
    }

    func testBoldUnwrapsSelectionInsideMarkers() {
        let result = MarkdownFormatting.toggleInline(.bold, in: "hello **world**", selection: NSRange(location: 8, length: 5))
        assertResult(result, text: "hello world", selection: NSRange(location: 6, length: 5))
    }

    func testBoldUnwrapsSelectedMarkers() {
        let result = MarkdownFormatting.toggleInline(.bold, in: "**world**", selection: NSRange(location: 0, length: 9))
        assertResult(result, text: "world", selection: NSRange(location: 0, length: 5))
    }

    func testBoldInsertsAndRemovesEmptyPairAtCaret() {
        let inserted = MarkdownFormatting.toggleInline(.bold, in: "hello ", selection: NSRange(location: 6, length: 0))
        assertResult(inserted, text: "hello ****", selection: NSRange(location: 8, length: 0))

        let removed = MarkdownFormatting.toggleInline(.bold, in: inserted.text, selection: inserted.selection)
        assertResult(removed, text: "hello ", selection: NSRange(location: 6, length: 0))
    }

    func testItalicOnBoldAddsOneMarkerPerSide() {
        let result = MarkdownFormatting.toggleInline(.italic, in: "**x**", selection: NSRange(location: 2, length: 1))
        assertResult(result, text: "***x***", selection: NSRange(location: 3, length: 1))
    }

    func testItalicUnwrapsSingleMarkers() {
        let result = MarkdownFormatting.toggleInline(.italic, in: "*x*", selection: NSRange(location: 1, length: 1))
        assertResult(result, text: "x", selection: NSRange(location: 0, length: 1))
    }

    func testItalicUnwrapsOneMarkerFromBoldItalic() {
        let result = MarkdownFormatting.toggleInline(.italic, in: "***x***", selection: NSRange(location: 3, length: 1))
        assertResult(result, text: "**x**", selection: NSRange(location: 2, length: 1))
    }

    func testItalicWrapsSelectedBoldMarkers() {
        let result = MarkdownFormatting.toggleInline(.italic, in: "**x**", selection: NSRange(location: 0, length: 5))
        assertResult(result, text: "***x***", selection: NSRange(location: 1, length: 5))
    }

    func testStrikethroughToggles() {
        let added = MarkdownFormatting.toggleInline(.strikethrough, in: "x", selection: NSRange(location: 0, length: 1))
        assertResult(added, text: "~~x~~", selection: NSRange(location: 2, length: 1))

        let removed = MarkdownFormatting.toggleInline(.strikethrough, in: added.text, selection: added.selection)
        assertResult(removed, text: "x", selection: NSRange(location: 0, length: 1))
    }

    func testInlineCodeToggles() {
        let added = MarkdownFormatting.toggleInline(.code, in: "x", selection: NSRange(location: 0, length: 1))
        assertResult(added, text: "`x`", selection: NSRange(location: 1, length: 1))

        let removed = MarkdownFormatting.toggleInline(.code, in: added.text, selection: added.selection)
        assertResult(removed, text: "x", selection: NSRange(location: 0, length: 1))
    }

    func testBoldHandlesMultiLineSelection() {
        let result = MarkdownFormatting.toggleInline(.bold, in: "alpha\nbeta", selection: NSRange(location: 0, length: 10))
        assertResult(result, text: "**alpha\nbeta**", selection: NSRange(location: 2, length: 10))
    }

    func testInlineDoubleToggleRestoresText() {
        let source = "one two three"
        let first = MarkdownFormatting.toggleInline(.bold, in: source, selection: NSRange(location: 4, length: 3))
        let second = MarkdownFormatting.toggleInline(.bold, in: first.text, selection: first.selection)
        XCTAssertEqual(second.text, source)
        XCTAssertEqual(second.selection, NSRange(location: 4, length: 3))
    }

    // MARK: - Headings

    func testHeadingAddsToEverySelectedLine() {
        let result = MarkdownFormatting.toggleLine(.heading(level: 1), in: "alpha\nbeta", selection: NSRange(location: 0, length: 10))
        assertResult(result, text: "# alpha\n# beta", selection: NSRange(location: 0, length: 14))
    }

    func testHeadingTogglesOffWhenAllLinesAlreadyAtLevel() {
        let result = MarkdownFormatting.toggleLine(.heading(level: 1), in: "# alpha\n# beta", selection: NSRange(location: 0, length: 14))
        assertResult(result, text: "alpha\nbeta", selection: NSRange(location: 0, length: 10))
    }

    func testHeadingReplacesExistingLevel() {
        let result = MarkdownFormatting.toggleLine(.heading(level: 2), in: "# alpha\n## beta", selection: NSRange(location: 0, length: 14))
        assertResult(result, text: "## alpha\n## beta", selection: NSRange(location: 0, length: 15))
    }

    func testHeadingOnEmptyDocumentInsertsMarkerForTyping() {
        let result = MarkdownFormatting.toggleLine(.heading(level: 3), in: "", selection: NSRange(location: 0, length: 0))
        assertResult(result, text: "### ", selection: NSRange(location: 4, length: 0))
    }

    func testHeadingKeepsCaretOffsetInsideLine() {
        let result = MarkdownFormatting.toggleLine(.heading(level: 1), in: "alpha", selection: NSRange(location: 2, length: 0))
        assertResult(result, text: "# alpha", selection: NSRange(location: 4, length: 0))
    }

    func testHeadingSkipsBlankLinesInMultiLineSelection() {
        let result = MarkdownFormatting.toggleLine(.heading(level: 2), in: "alpha\n\nbeta", selection: NSRange(location: 0, length: 11))
        assertResult(result, text: "## alpha\n\n## beta", selection: NSRange(location: 0, length: 17))
    }

    func testHeadingPreservesIndentation() {
        let result = MarkdownFormatting.toggleLine(.heading(level: 1), in: "  alpha", selection: NSRange(location: 2, length: 5))
        assertResult(result, text: "  # alpha", selection: NSRange(location: 4, length: 5))
    }

    // MARK: - Lists

    func testUnorderedListAddsAndRemoves() {
        let added = MarkdownFormatting.toggleLine(.unorderedList, in: "alpha\nbeta", selection: NSRange(location: 0, length: 10))
        assertResult(added, text: "- alpha\n- beta", selection: NSRange(location: 0, length: 14))

        let removed = MarkdownFormatting.toggleLine(.unorderedList, in: added.text, selection: added.selection)
        assertResult(removed, text: "alpha\nbeta", selection: NSRange(location: 0, length: 10))
    }

    func testUnorderedListConvertsOrderedItems() {
        let result = MarkdownFormatting.toggleLine(.unorderedList, in: "1. one\n2) two", selection: NSRange(location: 0, length: 13))
        assertResult(result, text: "- one\n- two", selection: NSRange(location: 0, length: 11))
    }

    func testUnorderedListAddsToMixedSelection() {
        let result = MarkdownFormatting.toggleLine(.unorderedList, in: "- alpha\nbeta", selection: NSRange(location: 0, length: 12))
        assertResult(result, text: "- alpha\n- beta", selection: NSRange(location: 0, length: 14))
    }

    func testOrderedListNumbersSequentially() {
        let result = MarkdownFormatting.toggleLine(.orderedList, in: "alpha\nbeta\ngamma", selection: NSRange(location: 0, length: 16))
        assertResult(result, text: "1. alpha\n2. beta\n3. gamma", selection: NSRange(location: 0, length: 25))
    }

    func testOrderedListContinuesFromPreviousNumber() {
        let result = MarkdownFormatting.toggleLine(.orderedList, in: "1. alpha\nbeta", selection: NSRange(location: 9, length: 4))
        assertResult(result, text: "1. alpha\n2. beta", selection: NSRange(location: 9, length: 7))
    }

    func testOrderedListTogglesOff() {
        let result = MarkdownFormatting.toggleLine(.orderedList, in: "1. one\n2. two", selection: NSRange(location: 0, length: 13))
        assertResult(result, text: "one\ntwo", selection: NSRange(location: 0, length: 7))
    }

    func testUnorderedListOnEmptyLinePreparesItem() {
        let result = MarkdownFormatting.toggleLine(.unorderedList, in: "", selection: NSRange(location: 0, length: 0))
        assertResult(result, text: "- ", selection: NSRange(location: 2, length: 0))
    }

    // MARK: - Blockquote

    func testBlockquoteAddsToNonBlankLines() {
        let result = MarkdownFormatting.toggleLine(.blockquote, in: "alpha\n\nbeta", selection: NSRange(location: 0, length: 11))
        assertResult(result, text: "> alpha\n\n> beta", selection: NSRange(location: 0, length: 15))
    }

    func testBlockquoteTogglesOff() {
        let result = MarkdownFormatting.toggleLine(.blockquote, in: "> alpha\n> beta", selection: NSRange(location: 0, length: 14))
        assertResult(result, text: "alpha\nbeta", selection: NSRange(location: 0, length: 10))
    }

    // MARK: - Code block

    func testCodeBlockWrapsSelection() {
        let result = MarkdownFormatting.toggleLine(.codeBlock, in: "alpha\nbeta", selection: NSRange(location: 0, length: 10))
        assertResult(result, text: "```\nalpha\nbeta\n```", selection: NSRange(location: 4, length: 10))
    }

    func testCodeBlockUnwrapsSelectionInsideFences() {
        let source = "```\nalpha\nbeta\n```"
        let result = MarkdownFormatting.toggleLine(.codeBlock, in: source, selection: NSRange(location: 4, length: 10))
        assertResult(result, text: "alpha\nbeta\n", selection: NSRange(location: 0, length: 10))
    }

    func testCodeBlockWrapsSingleLine() {
        let result = MarkdownFormatting.toggleLine(.codeBlock, in: "alpha", selection: NSRange(location: 0, length: 5))
        assertResult(result, text: "```\nalpha\n```", selection: NSRange(location: 4, length: 5))
    }

    func testCodeBlockOnEmptyDocumentPositionsCaretInside() {
        let result = MarkdownFormatting.toggleLine(.codeBlock, in: "", selection: NSRange(location: 0, length: 0))
        assertResult(result, text: "```\n\n```", selection: NSRange(location: 4, length: 0))
    }

    // MARK: - Links

    func testLinkWrapsSelectionAndSelectsURLPlaceholder() {
        let result = MarkdownFormatting.insertLink(in: "docs", selection: NSRange(location: 0, length: 4), url: nil)
        assertResult(result, text: "[docs](url)", selection: NSRange(location: 7, length: 3))
    }

    func testLinkUsesSuppliedURL() {
        let result = MarkdownFormatting.insertLink(
            in: "docs",
            selection: NSRange(location: 0, length: 4),
            url: "https://example.com"
        )
        assertResult(result, text: "[docs](https://example.com)", selection: NSRange(location: 27, length: 0))
    }

    func testLinkWithCaretInsertsSelectableLabel() {
        let result = MarkdownFormatting.insertLink(in: "hello ", selection: NSRange(location: 6, length: 0), url: nil)
        assertResult(result, text: "hello [text](url)", selection: NSRange(location: 7, length: 4))
    }

    // MARK: - List indentation

    func testIndentListAddsTwoSpaces() {
        let result = MarkdownFormatting.adjustListIndent(in: "- alpha\n- beta", selection: NSRange(location: 0, length: 14), outdent: false)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.text, "  - alpha\n  - beta")
        XCTAssertEqual(result?.selection, NSRange(location: 0, length: 18))
    }

    func testOutdentListRemovesUpToTwoSpaces() {
        let result = MarkdownFormatting.adjustListIndent(in: "  - alpha\n  - beta", selection: NSRange(location: 0, length: 18), outdent: true)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.text, "- alpha\n- beta")
        XCTAssertEqual(result?.selection, NSRange(location: 0, length: 14))
    }

    func testOutdentAtColumnZeroConsumesWithoutChange() {
        let result = MarkdownFormatting.adjustListIndent(in: "- alpha", selection: NSRange(location: 0, length: 0), outdent: true)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.text, "- alpha")
        XCTAssertEqual(result?.didChange, false)
    }

    func testIndentIgnoresNonListSelection() {
        XCTAssertNil(MarkdownFormatting.adjustListIndent(in: "alpha", selection: NSRange(location: 0, length: 5), outdent: false))
    }
}
