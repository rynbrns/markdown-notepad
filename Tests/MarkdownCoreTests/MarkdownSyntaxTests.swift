import Foundation
import XCTest
@testable import MarkdownCore

final class MarkdownSyntaxTests: XCTestCase {
    private func kinds(_ text: String) -> [(MarkdownSyntaxSpan.Kind, NSRange)] {
        MarkdownSyntax.spans(in: text).map { ($0.kind, $0.range) }
    }

    private func text(_ source: String, _ range: NSRange) -> String {
        (source as NSString).substring(with: range)
    }

    // MARK: - Blocks

    func testHeadingsAndLevels() {
        let source = "# One\n## Two\n###### Six"
        let spans = MarkdownSyntax.spans(in: source)
        XCTAssertEqual(spans.count, 3)
        XCTAssertEqual(spans[0].kind, .heading(level: 1))
        XCTAssertEqual(spans[1].kind, .heading(level: 2))
        XCTAssertEqual(spans[2].kind, .heading(level: 6))
        XCTAssertEqual(text(source, spans[0].range).trimmingCharacters(in: .whitespacesAndNewlines), "# One")
    }

    func testNotAHeadingWithoutSpace() {
        XCTAssertTrue(MarkdownSyntax.spans(in: "#hashtag").isEmpty)
        XCTAssertTrue(MarkdownSyntax.spans(in: "    # indented code").isEmpty)
    }

    func testListMarkersAndTaskMarkers() {
        let source = "- item\n* item\n+ item\n12. item\n- [ ] open\n- [x] done"
        let spans = MarkdownSyntax.spans(in: source)
        let listMarkers = spans.filter { $0.kind == .listMarker }.map { text(source, $0.range) }
        XCTAssertEqual(listMarkers, ["-", "*", "+", "12.", "-", "-"])
        let tasks = spans.filter { $0.kind == .taskMarker }.map { text(source, $0.range) }
        XCTAssertEqual(tasks, ["[ ]", "[x]"])
    }

    func testBlockQuote() {
        let source = "> quoted line"
        let spans = MarkdownSyntax.spans(in: source)
        XCTAssertTrue(spans.contains { $0.kind == .blockQuote })
    }

    func testFencedCodeBlockIsOneCoalescedSpan() {
        let source = "Before\n\n```swift\nlet x = \"# not a heading\"\n- not a list\n```\n\nAfter"
        let spans = MarkdownSyntax.spans(in: source)
        let code = spans.filter { $0.kind == .codeBlock }
        XCTAssertEqual(code.count, 1, "A fenced block should coalesce into one span")
        XCTAssertTrue(text(source, code[0].range).contains("let x"))
        XCTAssertTrue(text(source, code[0].range).contains("- not a list"))
        XCTAssertFalse(spans.contains { $0.kind == .listMarker })
        XCTAssertFalse(spans.contains { $0.kind == .heading(level: 1) })
    }

    func testUnclosedFenceRunsToEnd() {
        let source = "```\nstill code\nmore code"
        let spans = MarkdownSyntax.spans(in: source)
        let code = spans.filter { $0.kind == .codeBlock }
        XCTAssertEqual(code.count, 1)
        XCTAssertEqual(code[0].range.length, (source as NSString).length)
    }

    func testTableHeaderDelimiterAndRows() {
        let source = "| A | B |\n| --- | --- |\n| 1 | 2 |"
        let spans = MarkdownSyntax.spans(in: source)
        XCTAssertTrue(spans.contains { $0.kind == .tableHeader })
        XCTAssertTrue(spans.contains { $0.kind == .tableDelimiter })
        XCTAssertEqual(spans.filter { $0.kind == .tableRow }.count, 1)
    }

    // MARK: - Inline

    func testInlineStyles() {
        let source = "**bold** and *italic* and `code` and ~~gone~~ and [link](https://x.test)"
        let spans = MarkdownSyntax.spans(in: source)
        XCTAssertTrue(spans.contains { $0.kind == .strong })
        XCTAssertTrue(spans.contains { $0.kind == .emphasis })
        XCTAssertTrue(spans.contains { $0.kind == .codeSpan })
        XCTAssertTrue(spans.contains { $0.kind == .strikethrough })
        XCTAssertTrue(spans.contains { $0.kind == .link })

        let strong = spans.first { $0.kind == .strong }!
        XCTAssertEqual(text(source, strong.range), "**bold**")
        let link = spans.first { $0.kind == .link }!
        XCTAssertEqual(text(source, link.range), "[link](https://x.test)")
    }

    func testInlineInsideCodeSpanIsNotStyledSeparately() {
        let source = "`**not bold** [not a link](x)`"
        let spans = MarkdownSyntax.spans(in: source)
        XCTAssertEqual(spans.map(\.kind), [.codeSpan])
    }

    func testEscapedMarkersAreIgnored() {
        let source = "\\*not emphasis\\* and \\`not code\\`"
        XCTAssertTrue(MarkdownSyntax.spans(in: source).isEmpty)
    }

    func testImageSpan() {
        let source = "![alt text](images/a.png)"
        let spans = MarkdownSyntax.spans(in: source)
        XCTAssertEqual(spans.map(\.kind), [.image])
        XCTAssertEqual(text(source, spans[0].range), source)
    }

    // MARK: - Integrity

    func testRangesAreSortedAndInBounds() {
        let source = "# Title\n\n- [x] **done** with `code` and [link](a.md)\n\n| a | b |\n| - | - |\n| 1 | 2 |\n"
        let ns = source as NSString
        let spans = MarkdownSyntax.spans(in: source)
        XCTAssertFalse(spans.isEmpty)
        var previousEnd = 0
        for span in spans {
            XCTAssertGreaterThanOrEqual(span.range.location, 0)
            XCTAssertLessThanOrEqual(span.range.location + span.range.length, ns.length)
            XCTAssertGreaterThanOrEqual(span.range.location, previousEnd)
            previousEnd = span.range.location + span.range.length
        }
    }

    func testEmptyAndWhitespaceOnlyText() {
        XCTAssertTrue(MarkdownSyntax.spans(in: "").isEmpty)
        XCTAssertTrue(MarkdownSyntax.spans(in: "\n\n   \n").isEmpty)
    }

    func testUnicodeRangesStayInUTF16Space() {
        let source = "# Héllo 🌍\n\n- **日本語** text\n"
        let ns = source as NSString
        for span in MarkdownSyntax.spans(in: source) {
            XCTAssertLessThanOrEqual(span.range.location + span.range.length, ns.length)
        }
    }

    // MARK: - Performance

    func testOneMegabyteHighlightParseIsFast() {
        let block = """
        # Section heading

        A paragraph with **strong**, *emphasis*, `code`, ~~strike~~, and a [link](https://example.com/a?b=c).

        - [ ] open task
        - [x] finished task
        - plain bullet

        > A quote line with `code`.

        ```swift
        let value = "not a heading # nope"
        let other = "still code"
        ```

        | Name | Value | Note |
        | :--- | :---: | ---: |
        | a | 1 | left |
        | b | 2 | right |

        """

        var source = ""
        source.reserveCapacity(1_050_000)
        while source.utf8.count < 1_000_000 {
            source += block
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let spans = MarkdownSyntax.spans(in: source)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

        print(String(
            format: "1 MB markdown highlight parse: %.1f ms, %d bytes, %d spans",
            elapsed,
            source.utf8.count,
            spans.count
        ))

        XCTAssertGreaterThan(spans.count, 10_000)
        XCTAssertLessThan(elapsed, 3_000, "1 MB parse must stay well below a beachball (3 s CI ceiling)")
    }
}
