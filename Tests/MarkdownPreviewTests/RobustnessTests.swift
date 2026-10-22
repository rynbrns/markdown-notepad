import Foundation
import XCTest
@testable import MarkdownPreview

final class PreviewRobustnessTests: XCTestCase {
    private func measure(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    func testDeeplyNestedMarkdownStopsAtTheDepthLimitInsteadOfOverflowing() {
        let deep = String(repeating: "> ", count: 5_000) + "deep text"
        var html = ""
        let elapsed = measure { html = MarkdownPreviewRenderer.fragment(markdown: deep) }
        print(String(format: "deep nesting render: %d bytes in %.1f ms", deep.utf8.count, elapsed))
        XCTAssertTrue(html.contains("deeply nested content was simplified"))
        XCTAssertTrue(html.contains("deep text"))
        XCTAssertLessThan(elapsed, 2_000)
    }

    func testHugeTableRendersInBoundedTime() {
        var table = "| Name | Value |\n| --- | --- |\n"
        for row in 1...5_000 {
            table += "| row \(row) | value \(row) |\n"
        }
        var html = ""
        let elapsed = measure {
            html = MarkdownPreviewRenderer.documentHTML(markdown: table)
        }
        print(String(format: "huge table render: %d rows in %.1f ms", 5_000, elapsed))
        XCTAssertTrue(html.contains("<td>row 5000</td>"))
        XCTAssertLessThan(elapsed, 5_000)
    }

    func testMissingLocalImageIsLeftToTheWebViewWithoutCrashing() {
        let html = MarkdownPreviewRenderer.fragment(markdown: "![missing](images/missing.png)")
        XCTAssertTrue(html.contains("<img src=\"images/missing.png\" alt=\"missing\">"))
    }

    func testMalformedMarkdownRendersWithoutHanging() {
        let cases = [
            "| not | a table\n---\n",
            "```\nunclosed fence\n",
            String(repeating: "[", count: 20_000),
            String(repeating: "*", count: 20_000),
            "![alt](<script>alert(1)</script>)",
            "<script>alert('x')</script>\n\n# heading"
        ]
        for source in cases {
            let elapsed = measure {
                let html = MarkdownPreviewRenderer.documentHTML(markdown: source)
                XCTAssertFalse(html.isEmpty)
                XCTAssertTrue(html.contains("Content-Security-Policy"))
            }
            XCTAssertLessThan(elapsed, 1_500, "Malformed input must not hang the renderer")
        }
    }
}
