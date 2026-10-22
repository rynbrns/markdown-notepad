import XCTest
@testable import MarkdownCore

final class MarkdownDocumentTests: XCTestCase {
    func testEmptyDocument() {
        let document = MarkdownDocument()
        XCTAssertTrue(document.isEmpty)
        XCTAssertTrue(document.isBlank)
        XCTAssertEqual(document.lineCount, 0)
        XCTAssertEqual(document.wordCount, 0)
        XCTAssertEqual(document.utf8ByteCount, 0)
    }

    func testSingleLine() {
        let document = MarkdownDocument(text: "hello world")
        XCTAssertFalse(document.isEmpty)
        XCTAssertFalse(document.isBlank)
        XCTAssertEqual(document.lineCount, 1)
        XCTAssertEqual(document.wordCount, 2)
        XCTAssertEqual(document.utf8ByteCount, 11)
    }

    func testTrailingNewlineStartsNewLine() {
        let document = MarkdownDocument(text: "first\nsecond\n")
        XCTAssertEqual(document.lineCount, 3)
        XCTAssertEqual(document.wordCount, 2)
    }

    func testBlankDocumentWithWhitespace() {
        let document = MarkdownDocument(text: " \n\t\n")
        XCTAssertFalse(document.isEmpty)
        XCTAssertTrue(document.isBlank)
        XCTAssertEqual(document.lineCount, 3)
        XCTAssertEqual(document.wordCount, 0)
    }

    func testUnicodeByteCountAndWords() {
        let document = MarkdownDocument(text: "café déjà vu")
        XCTAssertEqual(document.wordCount, 3)
        XCTAssertEqual(document.utf8ByteCount, 15)
    }

    func testStatistics() {
        let document = MarkdownDocument(text: "one two\nthree")
        XCTAssertEqual(
            document.statistics,
            DocumentStatistics(lineCount: 2, wordCount: 3, utf8ByteCount: 13)
        )
    }
}
