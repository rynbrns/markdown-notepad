import Foundation
import XCTest
@testable import MarkdownCore

final class RecoveryStoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var store: RecoveryStore!

    override func setUpWithError() throws {
        tempDirectory = try makeTempDirectory()
        store = RecoveryStore(directory: tempDirectory.appendingPathComponent("Recovery", isDirectory: true))
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            removeTempDirectory(tempDirectory)
        }
    }

    private func snapshot(
        id: String = "file-abc",
        fileURL: String? = "/Users/test/Notes/note.md",
        text: String = "unsaved text\n",
        savedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> RecoverySnapshot {
        RecoverySnapshot(
            documentID: id,
            fileURL: fileURL,
            text: text,
            format: TextFileFormat(hasBOM: true, lineEnding: .crlf, originalLineEndings: [.crlf]),
            baseline: FileFingerprint(byteCount: 12, modificationTime: 1_699_999_000, sha256: "abc123"),
            savedAt: savedAt
        )
    }

    func testSaveAndLoadRoundTrip() throws {
        let original = snapshot()
        try store.save(original)
        let loaded = try XCTUnwrap(store.load(documentID: original.documentID))
        XCTAssertEqual(loaded, original)
        XCTAssertEqual(loaded.textFile.format, original.format)
    }

    func testSaveIsIdempotentAndReplacesOldSnapshot() throws {
        try store.save(snapshot(text: "first\n"))
        try store.save(snapshot(text: "second\n"))
        let loaded = try XCTUnwrap(store.load(documentID: "file-abc"))
        XCTAssertEqual(loaded.text, "second\n")
        XCTAssertEqual(try store.loadAll().count, 1)
    }

    func testDeleteRemovesSnapshotAndIsIdempotent() throws {
        try store.save(snapshot())
        try store.delete(documentID: "file-abc")
        XCTAssertNil(try store.load(documentID: "file-abc"))
        XCTAssertNoThrow(try store.delete(documentID: "file-abc"))
    }

    func testDeleteForFileURLUsesStableIdentifier() throws {
        let documentURL = tempDirectory.appendingPathComponent("note.md")
        let id = RecoveryStore.documentID(for: documentURL)
        try store.save(snapshot(id: id, fileURL: documentURL.path))
        XCTAssertNotNil(try store.load(for: documentURL))
        try store.delete(for: documentURL)
        XCTAssertNil(try store.load(for: documentURL))
    }

    func testSnapshotsAreNeverWrittenIntoTheDocumentFolder() throws {
        let documentFolder = tempDirectory.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documentFolder, withIntermediateDirectories: true)
        let documentURL = documentFolder.appendingPathComponent("note.md")
        try Data("on disk\n".utf8).write(to: documentURL)

        try store.save(snapshot(id: RecoveryStore.documentID(for: documentURL), fileURL: documentURL.path))

        let documentFolderContents = try FileManager.default.contentsOfDirectory(atPath: documentFolder.path)
        XCTAssertEqual(documentFolderContents, ["note.md"])
        let recoveryContents = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        XCTAssertEqual(recoveryContents.count, 1)
        XCTAssertTrue(recoveryContents[0].hasSuffix(".json"))
    }

    func testLoadAllReturnsNewestFirst() throws {
        try store.save(snapshot(id: "file-old", savedAt: Date(timeIntervalSince1970: 100)))
        try store.save(snapshot(id: "file-new", savedAt: Date(timeIntervalSince1970: 300)))
        try store.save(snapshot(id: "file-mid", savedAt: Date(timeIntervalSince1970: 200)))
        let all = try store.loadAll()
        XCTAssertEqual(all.map(\.documentID), ["file-new", "file-mid", "file-old"])
    }

    func testDeleteAllClearsRecoveryAfterCleanQuit() throws {
        try store.save(snapshot(id: "file-one"))
        try store.save(snapshot(id: "file-two"))
        try store.deleteAll()
        XCTAssertEqual(try store.loadAll(), [])
    }

    func testMissingStoreDirectoryLoadsEmpty() throws {
        let emptyStore = RecoveryStore(directory: tempDirectory.appendingPathComponent("does-not-exist"))
        XCTAssertEqual(try emptyStore.loadAll(), [])
        XCTAssertNil(try emptyStore.load(documentID: "file-abc"))
    }

    func testCorruptSnapshotIsIgnoredRatherThanCrashing() throws {
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.directory.appendingPathComponent("broken.json"))
        XCTAssertEqual(try store.loadAll(), [])
        XCTAssertNil(try store.load(documentID: "file-abc"))
    }

    func testDocumentIdentifiersAreStableAndDistinct() {
        let first = URL(fileURLWithPath: "/Users/test/Notes/a.md")
        let same = URL(fileURLWithPath: "/Users/test/Notes/a.md")
        let other = URL(fileURLWithPath: "/Users/test/Notes/b.md")
        XCTAssertEqual(RecoveryStore.documentID(for: first), RecoveryStore.documentID(for: same))
        XCTAssertNotEqual(RecoveryStore.documentID(for: first), RecoveryStore.documentID(for: other))
        XCTAssertTrue(RecoveryStore.documentID(for: first).hasPrefix("file-"))
        XCTAssertTrue(RecoveryStore.documentID(forUntitled: UUID()).hasPrefix("untitled-"))
    }

    func testDefaultDirectoryIsUnderApplicationSupport() {
        let path = RecoveryStore.defaultDirectory().path
        XCTAssertTrue(path.contains("Application Support") || path.contains("MarkdownNotepad"))
        XCTAssertTrue(path.hasSuffix("MarkdownNotepad/Recovery"))
    }
}
