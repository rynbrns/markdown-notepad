import Foundation
import XCTest
@testable import MarkdownCore

final class MarkdownPresentationTests: XCTestCase {
    private func text(_ source: String, _ range: NSRange) -> String {
        (source as NSString).substring(with: range)
    }

    private func runs(_ source: String, _ style: MarkdownPresentation.Style) -> [String] {
        MarkdownPresentation.runs(in: source)
            .filter { $0.style == style }
            .map { text(source, $0.range) }
    }

    private func hidden(_ source: String) -> [String] {
        runs(source, .hidden)
    }

    func testHeadingHidesHashesAndKeepsContent() {
        let source = "## A title"
        XCTAssertEqual(hidden(source), ["## "])
        XCTAssertEqual(runs(source, .heading(level: 2)), ["A title"])
    }

    func testStrongEmphasisAndStrikethroughHideOnlyMarkers() {
        let source = "**bold** *italic* ~~gone~~"
        XCTAssertEqual(runs(source, .strong), ["bold"])
        XCTAssertEqual(runs(source, .emphasis), ["italic"])
        XCTAssertEqual(runs(source, .strikethrough), ["gone"])
        XCTAssertEqual(hidden(source), ["**", "**", "*", "*", "~~", "~~"])
    }

    func testCodeSpanHidesBackticks() {
        let source = "Use ``a ` b`` here"
        XCTAssertEqual(runs(source, .code), ["a ` b"])
        XCTAssertEqual(hidden(source), ["``", "``"])
    }

    func testLinkKeepsOnlyTheLabelVisible() {
        let source = "[label](https://example.test/a)"
        XCTAssertEqual(runs(source, .link), ["label"])
        XCTAssertEqual(hidden(source), ["[", "](https://example.test/a)"])
    }

    func testImageKeepsAltTextVisible() {
        let source = "![alt](images/a.png)"
        XCTAssertEqual(runs(source, .image), ["alt"])
        XCTAssertEqual(hidden(source), ["![", "](images/a.png)"])
    }

    func testBlockQuoteHidesTheMarker() {
        let source = "> quoted words"
        XCTAssertEqual(hidden(source), ["> "])
        XCTAssertEqual(runs(source, .blockQuote), ["quoted words"])
    }

    func testListAndTaskMarkersStayVisible() {
        let source = "- [x] done\n- [ ] open"
        XCTAssertEqual(runs(source, .listMarker), ["-", "-"])
        XCTAssertEqual(runs(source, .taskMarker), ["[x]", "[ ]"])
    }

    func testFencedCodeHidesFenceLinesAndKeepsCode() {
        let source = "Before\n\n```swift\nlet value = \"# not a heading\"\n```\n\nAfter"
        let code = runs(source, .codeBlock)
        XCTAssertEqual(code, ["let value = \"# not a heading\""])
        XCTAssertTrue(hidden(source).contains("```swift\n"))
        XCTAssertTrue(hidden(source).contains("```\n"))
        XCTAssertFalse(code.joined().contains("```"))
    }

    func testUnclosedInlineMarkerIsLeftAlone() {
        let source = "**unclosed"
        XCTAssertTrue(MarkdownPresentation.runs(in: source).isEmpty)
        XCTAssertTrue(MarkdownPresentation.runs(in: "a * b").isEmpty)
    }

    func testRunsAreSortedInBoundsAndNonOverlapping() {
        let source = """
        # Title

        A **strong** line with *emphasis*, `code`, ~~strike~~, [link](a.md) and ![alt](b.png).

        - [x] task
        > quote
        ```swift
        let x = 1
        ```
        | A | B |
        | - | - |
        | 1 | 2 |
        """
        let length = (source as NSString).length
        let presentation = MarkdownPresentation.runs(in: source)
        XCTAssertFalse(presentation.isEmpty)
        var previousEnd = 0
        for run in presentation {
            XCTAssertGreaterThanOrEqual(run.range.location, 0)
            XCTAssertLessThanOrEqual(run.range.location + run.range.length, length)
            XCTAssertGreaterThanOrEqual(run.range.location, previousEnd)
            previousEnd = run.range.location + run.range.length
        }
    }

    func testOrdinarySymbolsAndEscapesStayVisible() {
        XCTAssertTrue(MarkdownPresentation.runs(in: "2 * 3 = 6").isEmpty)
        XCTAssertTrue(MarkdownPresentation.runs(in: "\\*not emphasis\\*").isEmpty)
        XCTAssertTrue(MarkdownPresentation.runs(in: "a | b | c").isEmpty)
    }

    func testOneMegabytePresentationStaysFast() {
        var source = ""
        while source.utf8.count < 1_000_000 {
            source += "# Heading\n\nA **bold** line with `code` and [a link](https://example.test).\n\n"
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let presentation = MarkdownPresentation.runs(in: source)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print(String(format: "1 MB presentation mapping: %.1f ms, %d runs", elapsed, presentation.count))
        XCTAssertGreaterThan(presentation.count, 1_000)
        XCTAssertLessThan(elapsed, 3_000, "1 MB presentation mapping must stay below the 3 s CI ceiling")
    }
}
