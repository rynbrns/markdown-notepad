import Foundation
import XCTest
@testable import MarkdownCore

final class MarkdownSyntaxIndexTests: XCTestCase {
    private func assertMatchesFullScan(
        _ index: MarkdownSyntaxIndex,
        _ text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            index.allSpans(),
            MarkdownSyntax.spans(in: text),
            "Incremental cache diverged from a full scan",
            file: file,
            line: line
        )
    }

    func testTypingAtEndOnlyRescansTheTail() {
        var text = (1...200).map { "Line \($0) with **bold** and `code`" }.joined(separator: "\n")
        var index = MarkdownSyntaxIndex()
        index.rebuild(with: text)

        let insertionOffset = (text as NSString).length
        text += " and more"
        let update = index.update(text: text, changedOffsetHint: insertionOffset)

        XCTAssertFalse(update.didRebuildEntireDocument)
        XCTAssertLessThan(update.affectedRange.length, 120, "A tail edit must not rescan the document")
        assertMatchesFullScan(index, text)
    }

    func testTypingAtStartFallsBackToCorrectSpans() {
        var text = (1...500).map { "Line \($0) with *emphasis*" }.joined(separator: "\n")
        var index = MarkdownSyntaxIndex()
        index.rebuild(with: text)

        text = "Intro **new**\n" + text
        let update = index.update(text: text, changedOffsetHint: 3)

        assertMatchesFullScan(index, text)
        XCTAssertNotNil(update)
    }

    func testEnterAndDeletingALineKeepSpansCorrect() {
        var text = "Alpha\nBravo\nCharlie\nDelta\nEcho"
        var index = MarkdownSyntaxIndex()
        index.rebuild(with: text)

        let afterBravo = (text as NSString).range(of: "Charlie").location
        text = "Alpha\nBravo\nCharlie\nnew line\nDelta\nEcho"
        _ = index.update(text: text, changedOffsetHint: afterBravo)
        assertMatchesFullScan(index, text)

        text = "Alpha\nBravo\nCharlie\nDelta\nEcho"
        _ = index.update(text: text, changedOffsetHint: afterBravo)
        assertMatchesFullScan(index, text)

        text = "Alpha\nBravo\nDelta\nEcho"
        _ = index.update(text: text, changedOffsetHint: afterBravo)
        assertMatchesFullScan(index, text)
    }

    func testOpeningACodeFenceRehighlightsFollowingLines() {
        var text = "# Heading\n\nA paragraph\n\n- item"
        var index = MarkdownSyntaxIndex()
        index.rebuild(with: text)

        let fenceOffset = (text as NSString).range(of: "A paragraph").location
        text = "# Heading\n\n```\nA paragraph\n\n- item\n```"
        let update = index.update(text: text, changedOffsetHint: fenceOffset)

        assertMatchesFullScan(index, text)
        XCTAssertTrue(update.spans.contains { $0.kind == .codeBlock })
        XCTAssertFalse(index.allSpans().contains { $0.kind == .listMarker })
        XCTAssertLessThanOrEqual(update.affectedRange.location, fenceOffset)
    }

    func testTableHeaderTracksEditsToTheDelimiterLine() {
        var text = "| Name | Value |\n| --- | --- |\n| a | 1 |"
        var index = MarkdownSyntaxIndex()
        index.rebuild(with: text)

        let delimiterOffset = (text as NSString).range(of: "---").location
        text = "| Name | Value |\n| a | 1 |"
        _ = index.update(text: text, changedOffsetHint: delimiterOffset)
        assertMatchesFullScan(index, text)
        XCTAssertFalse(index.allSpans().contains { $0.kind == .tableHeader })

        text = "| Name | Value |\n| --- | --- |\n| a | 1 |"
        _ = index.update(text: text, changedOffsetHint: delimiterOffset)
        assertMatchesFullScan(index, text)
        XCTAssertTrue(index.allSpans().contains { $0.kind == .tableHeader })
    }

    func testManyEditsAcrossTheDocumentStayConsistent() {
        var text = (1...120).map { line -> String in
            switch line % 5 {
            case 0: return "## Heading \(line)"
            case 1: return "- item **bold**"
            case 2: return "> quote `code`"
            case 3: return "plain paragraph with [link](https://example.com)"
            default: return "| a | b |\n| --- | --- |\n| 1 | 2 |"
            }
        }.joined(separator: "\n\n")
        var index = MarkdownSyntaxIndex()
        index.rebuild(with: text)

        let edits: [(String, Int)] = [
            ("# ", 0),
            ("\n\n```\nunclosed code\n", (text as NSString).length),
            ("**", (text as NSString).range(of: "plain").location),
            ("\n\nnew paragraph\n", (text as NSString).range(of: "quote").location),
            ("deleted", (text as NSString).range(of: "Heading 10").location)
        ]
        for (insertion, offset) in edits {
            let safeOffset = min(offset, (text as NSString).length)
            text = (text as NSString).replacingCharacters(in: NSRange(location: safeOffset, length: 0), with: insertion)
            let update = index.update(text: text, changedOffsetHint: safeOffset + (insertion as NSString).length)
            assertMatchesFullScan(index, text)
            XCTAssertLessThanOrEqual(update.affectedRange.location + update.affectedRange.length, (text as NSString).length)
        }
    }

    // MARK: - Robustness

    private func measure(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    func testMalformedInputCannotMakeTheScannerQuadratic() {
        let cases = [
            String(repeating: "[", count: 200_000),
            String(repeating: "`a", count: 100_000),
            String(repeating: "*", count: 200_000),
            String(repeating: ">", count: 100_000),
            String(repeating: "| - ", count: 100_000),
            String(repeating: "- [", count: 100_000)
        ]
        for malformed in cases {
            let elapsed = measure {
                _ = MarkdownSyntax.spans(in: malformed)
            }
            print(String(format: "malformed scan: %d bytes in %.1f ms", malformed.utf8.count, elapsed))
            XCTAssertLessThan(elapsed, 2_000, "Pathological Markdown must scan in bounded time")
        }
    }

    func testDeeplyNestedListsAndHugeTableScanInBoundedTime() {
        let nested = (1...2_000).map { String(repeating: " ", count: $0 % 4) + "- item \($0)" }.joined(separator: "\n")
        let tableRows = (1...5_000).map { "| row \($0) | value \($0) |" }.joined(separator: "\n")
        let table = "| Name | Value |\n| --- | --- |\n" + tableRows

        for document in [nested, table] {
            let elapsed = measure {
                let spans = MarkdownSyntax.spans(in: document)
                XCTAssertFalse(spans.isEmpty)
            }
            print(String(format: "structural scan: %d bytes in %.1f ms", document.utf8.count, elapsed))
            XCTAssertLessThan(elapsed, 2_000)
        }
    }

    // MARK: - Performance

    private func performanceDocument(targetBytes: Int) -> String {
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
        source.reserveCapacity(targetBytes + block.utf8.count)
        while source.utf8.count < targetBytes {
            source += block
        }
        return source
    }

    func testIncrementalHighlightingIsFastAtOneAndTenMegabytes() {
        for target in [1_000_000, 10_000_000] {
            let text = performanceDocument(targetBytes: target)
            var index = MarkdownSyntaxIndex()

            let fullStart = DispatchTime.now().uptimeNanoseconds
            index.rebuild(with: text)
            let fullElapsed = Double(DispatchTime.now().uptimeNanoseconds - fullStart) / 1_000_000

            var edited = text
            let hint = (edited as NSString).length
            var worstUpdate = 0.0
            var editStart = DispatchTime.now().uptimeNanoseconds
            for iteration in 0..<25 {
                edited += "x"
                _ = index.update(text: edited, changedOffsetHint: hint + iteration)
            }
            let averageUpdate = Double(DispatchTime.now().uptimeNanoseconds - editStart) / 1_000_000 / 25
            XCTAssertEqual(index.allSpans(), MarkdownSyntax.spans(in: edited))
            worstUpdate = max(worstUpdate, averageUpdate)

            print(String(
                format: "highlight perf: %.1f MB full=%.1f ms tail-edit-avg=%.2f ms",
                Double(text.utf8.count) / 1_000_000,
                fullElapsed,
                averageUpdate
            ))

            XCTAssertLessThan(fullElapsed, 10_000, "A full scan must not beachball the app")
            XCTAssertLessThan(averageUpdate, 200, "Typing at the end must be incremental")
            XCTAssertLessThan(worstUpdate, 200)
        }
    }
}
