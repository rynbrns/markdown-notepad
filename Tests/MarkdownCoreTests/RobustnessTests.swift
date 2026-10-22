import Foundation
import XCTest
@testable import MarkdownCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class RobustnessTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownNotepadRobustness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporaryDirectory.path)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testSavingToReadOnlyFolderFailsWithoutTouchingTheOriginal() throws {
        #if os(Linux)
        if geteuid() == 0 {
            throw XCTSkip("Root can write through a read-only mode bit; run this on a non-root runner.")
        }
        #endif

        let url = temporaryDirectory.appendingPathComponent("notes.md")
        let original = TextFile(text: "original text\n", format: TextFileFormat())
        _ = try MarkdownFileIO().saveAs(original, to: url)
        let originalBytes = try Data(contentsOf: url)
        let fingerprint = try XCTUnwrap(MarkdownFileIO().fingerprint(of: url))

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: temporaryDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporaryDirectory.path)
        }

        let edited = TextFile(text: "edited\n", format: TextFileFormat())
        XCTAssertThrowsError(try MarkdownFileIO().save(edited, to: url, baseline: fingerprint)) { error in
            XCTAssertEqual(error as? MarkdownCoreError, .permissionDenied)
        }
        XCTAssertEqual(try Data(contentsOf: url), originalBytes, "A failed read-only save must not change the file")
    }

    func testLoadingFromReadOnlyFolderStillWorks() throws {
        let url = temporaryDirectory.appendingPathComponent("readme.md")
        let contents = "# Read only\n\nStill readable.\n"
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        let loaded = try MarkdownFileIO().load(from: url)
        XCTAssertEqual(loaded.textFile.text, contents)
    }

    func testMalformedMarkdownNeverThrowsFromTheFileLayer() throws {
        let url = temporaryDirectory.appendingPathComponent("broken.md")
        let malformed = "| not | a | table\n---\n```\n# not closed\n[link](\n**bold\n"
        try malformed.write(to: url, atomically: true, encoding: .utf8)
        let loaded = try MarkdownFileIO().load(from: url)
        XCTAssertEqual(loaded.textFile.text, malformed)
        XCTAssertFalse(MarkdownSyntax.spans(in: malformed).isEmpty)
    }

    func testReadOnlyErrorDescribesTheProblem() {
        let error = MarkdownCoreError.permissionDenied
        XCTAssertEqual(
            error.errorDescription,
            "You do not have permission to read or write this file. The original file was not changed."
        )
    }
}
