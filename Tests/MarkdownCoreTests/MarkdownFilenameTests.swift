import Foundation
import XCTest
@testable import MarkdownCore

final class MarkdownFilenameTests: XCTestCase {
    func testAppendsMarkdownExtensionWhenMissing() {
        XCTAssertEqual(MarkdownFilename.normalized("notes"), "notes.md")
        XCTAssertEqual(MarkdownFilename.normalized("  notes  "), "notes.md")
        XCTAssertEqual(MarkdownFilename.normalized("Meeting notes 2026"), "Meeting notes 2026.md")
    }

    func testKeepsExistingMarkdownExtensionInAnyCasing() {
        XCTAssertEqual(MarkdownFilename.normalized("notes.md"), "notes.md")
        XCTAssertEqual(MarkdownFilename.normalized("notes.MD"), "notes.MD")
        XCTAssertEqual(MarkdownFilename.normalized("notes.Md"), "notes.Md")
    }

    func testNeverDropsUserSuppliedExtension() {
        XCTAssertEqual(MarkdownFilename.normalized("notes.txt"), "notes.txt.md")
        XCTAssertEqual(MarkdownFilename.normalized("draft.markdown"), "draft.markdown.md")
    }

    func testRejectsUnsafeOrEmptyNames() {
        let rejected = [
            "",
            "   ",
            ".",
            "..",
            "../escape",
            "folder/name",
            "folder:name",
            "line\nbreak",
            "trailing dot.",
            ".hidden",
            "null\u{0}byte"
        ]
        for name in rejected {
            XCTAssertNil(MarkdownFilename.normalized(name), "\(name.debugDescription) should be rejected")
        }
    }

    func testEditableNameRemovesOnlyMarkdownExtension() {
        XCTAssertEqual(MarkdownFilename.editableName(for: "notes.md"), "notes")
        XCTAssertEqual(MarkdownFilename.editableName(for: "notes.MD"), "notes")
        XCTAssertEqual(MarkdownFilename.editableName(for: "notes.txt.md"), "notes.txt")
        XCTAssertEqual(MarkdownFilename.editableName(for: "Untitled"), "Untitled")
    }

    func testSameFileIgnoresRedundantPathComponents() {
        let base = URL(fileURLWithPath: "/tmp/notes.md")
        let messy = URL(fileURLWithPath: "/tmp/./notes.md")
        XCTAssertTrue(MarkdownFilename.isSameFile(base, messy))
        XCTAssertFalse(MarkdownFilename.isSameFile(base, URL(fileURLWithPath: "/tmp/other.md")))
    }
}
