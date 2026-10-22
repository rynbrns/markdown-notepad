import Foundation
import XCTest
@testable import MarkdownPreview

final class MarkdownPreviewRendererTests: XCTestCase {
    private func fixture(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Fixtures") else {
            fatalError("Missing fixture \(name).md")
        }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: - GFM coverage

    func testGFMFixtureRendersAllBlockAndInlineShapes() {
        let html = MarkdownPreviewRenderer.fragment(markdown: fixture("gfm"))

        XCTAssertTrue(html.contains("<h1>Heading One</h1>"), "H1 should render")
        XCTAssertTrue(html.contains("<h2>Heading Two with <em>emphasis</em></h2>"), "H2 and emphasis should render")
        XCTAssertTrue(html.contains("<strong>strong text</strong>"), "Strong should render")
        XCTAssertTrue(html.contains("<del>struck</del>"), "Strikethrough should render")
        XCTAssertTrue(html.contains("<code>inline code</code>"), "Inline code should render")
        XCTAssertTrue(html.contains("<a href=\"https://example.com/page?q=1&amp;x=2\" title=\"Example title\" rel=\"noopener noreferrer\">link to Example</a>"),
                      "Links should render with an escaped href")

        XCTAssertTrue(html.contains("<blockquote>"), "Block quote should render")
        XCTAssertTrue(html.contains("<a href=\"https://example.org/quote\""), "Links inside quotes should render")

        XCTAssertTrue(html.contains("<ul>"), "Unordered list should render")
        XCTAssertTrue(html.contains("<ol>"), "Ordered list should render")
        XCTAssertTrue(html.contains("<input type=\"checkbox\" disabled> <p>Open task</p>"), "Unchecked task should render")
        XCTAssertTrue(html.contains("<input type=\"checkbox\" disabled checked> <p>Done task</p>"), "Checked task should render")

        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">"), "Fenced code should keep its language")
        XCTAssertTrue(html.contains("let greeting = &quot;hello &lt;world&gt;&quot;"), "Code text should be escaped")

        XCTAssertTrue(html.contains("<table>"), "Table should render")
        XCTAssertTrue(html.contains("<thead>"), "Table head should render")
        XCTAssertTrue(html.contains("<th style=\"text-align: left\">Name</th>"), "Left alignment should render")
        XCTAssertTrue(html.contains("<th style=\"text-align: center\">Value</th>"), "Center alignment should render")
        XCTAssertTrue(html.contains("<td style=\"text-align: left\">alpha</td>"), "Body cell should render")
        XCTAssertTrue(html.contains("<td style=\"text-align: center\">1</td>"),
                      "Alignment follows the column, not the cell text")
        XCTAssertTrue(html.contains("<td style=\"text-align: right\">left</td>"),
                      "The third column is right-aligned even when its text is short")

        XCTAssertTrue(html.contains("<hr>"), "Thematic break should render")
        XCTAssertTrue(html.contains("<img src=\"images/diagram.png\" alt=\"diagram\">"),
                      "Local relative images should load")
        XCTAssertFalse(html.contains("<script"), "GFM fixture has no scripts")
    }

    func testEmptyDocumentRendersEmptyArticle() {
        let html = MarkdownPreviewRenderer.documentHTML(markdown: "", title: "Untitled")
        XCTAssertTrue(html.contains("<article class=\"markdown-body\">"))
        XCTAssertTrue(html.contains("<title>Untitled</title>"))
    }

    // MARK: - Hostile fixture

    func testHostileFixtureCannotExecuteScriptsOrLoadRemoteResources() {
        let source = fixture("hostile")
        let html = MarkdownPreviewRenderer.documentHTML(markdown: source, title: "Hostile")

        XCTAssertFalse(html.lowercased().contains("<script"), "Raw scripts must never reach the page")
        XCTAssertFalse(html.lowercased().contains("<iframe"), "Raw iframes must never reach the page")
        XCTAssertFalse(html.contains("<style>body"), "Raw style blocks must not become page styles")
        XCTAssertFalse(html.contains("<img src=\"https://evil.example/tracker.png\" onerror"),
                       "Event handler attributes must never become live attributes")
        XCTAssertFalse(html.lowercased().contains("href=\"javascript:"), "javascript: links must be dropped")
        XCTAssertFalse(html.contains("<img src=\"https://evil.example"), "Remote images must not become live tags")
        XCTAssertFalse(html.contains("<img src=\"//evil.example"), "Protocol-relative images must not become live tags")
        XCTAssertFalse(html.contains("<img src=\"file:"), "Absolute file images must not become live tags")
        XCTAssertTrue(html.contains("&lt;script&gt;window.alert(&quot;executed&quot;)&lt;/script&gt;"),
                      "Raw HTML should be shown as inert escaped text")
        XCTAssertTrue(html.contains("&lt;img src=&quot;https://evil.example/tracker.png&quot;"),
                      "Raw remote images should be shown as inert escaped text, not loaded")

        XCTAssertTrue(html.contains("[image blocked: remote]"), "Remote images should render a text placeholder")
        XCTAssertTrue(html.contains("<img src=\"pictures/ok.png\" alt=\"local\">"), "Local relative images stay allowed")
        XCTAssertTrue(html.contains("Normal <strong>text</strong> after the hostile payload."),
                      "Normal content after the payload should still render")
    }

    func testDocumentCarriesStrictCSPAndNoScriptPolicy() {
        let html = MarkdownPreviewRenderer.documentHTML(markdown: "# Hi", title: "Doc")
        XCTAssertTrue(html.contains("Content-Security-Policy"))
        XCTAssertTrue(html.contains("script-src 'none'"))
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertTrue(html.contains("img-src file: data:"))
        XCTAssertTrue(html.contains("object-src 'none'"))
        XCTAssertTrue(html.contains("form-action 'none'"))
    }

    func testLinkSchemeAllowList() {
        XCTAssertNotNil(MarkdownPreviewRenderer.sanitizedLinkURL("https://example.com"))
        XCTAssertNotNil(MarkdownPreviewRenderer.sanitizedLinkURL("http://example.com"))
        XCTAssertNotNil(MarkdownPreviewRenderer.sanitizedLinkURL("mailto:hi@example.com"))
        XCTAssertNotNil(MarkdownPreviewRenderer.sanitizedLinkURL("docs/page.md"))
        XCTAssertNotNil(MarkdownPreviewRenderer.sanitizedLinkURL("#section"))
        XCTAssertNil(MarkdownPreviewRenderer.sanitizedLinkURL("javascript:alert(1)"))
        XCTAssertNil(MarkdownPreviewRenderer.sanitizedLinkURL("data:text/html,<script>"))
        XCTAssertNil(MarkdownPreviewRenderer.sanitizedLinkURL("//example.com/x"))
    }

    func testImagePolicyAllowsOnlyLocalRelativePaths() {
        XCTAssertEqual(MarkdownPreviewRenderer.sanitizedImageURL("images/a.png"), "images/a.png")
        XCTAssertEqual(MarkdownPreviewRenderer.sanitizedImageURL("./a.png"), "./a.png")
        XCTAssertNil(MarkdownPreviewRenderer.sanitizedImageURL("https://example.com/a.png"))
        XCTAssertNil(MarkdownPreviewRenderer.sanitizedImageURL("//example.com/a.png"))
        XCTAssertNil(MarkdownPreviewRenderer.sanitizedImageURL("/absolute/a.png"))
        XCTAssertNil(MarkdownPreviewRenderer.sanitizedImageURL("data:image/png;base64,AAAA"))
    }

    // MARK: - Fidelity

    func testRenderingIsPureAndLeavesSourceUntouched() {
        let source = fixture("gfm")
        let copy = source
        _ = MarkdownPreviewRenderer.documentHTML(markdown: source)
        XCTAssertEqual(source, copy)
    }

    func testOutputIsDeterministic() {
        let source = fixture("gfm")
        XCTAssertEqual(
            MarkdownPreviewRenderer.documentHTML(markdown: source, title: "Doc"),
            MarkdownPreviewRenderer.documentHTML(markdown: source, title: "Doc")
        )
    }
}
