import Foundation
import XCTest
@testable import MarkdownCore

final class WorkspaceStoresTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = try makeTempDirectory()
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            removeTempDirectory(tempDirectory)
        }
    }

    private func makeStore() -> RecentDocumentsStore {
        RecentDocumentsStore(fileURL: tempDirectory.appendingPathComponent("Recent.json"))
    }

    func testRecentAddDeduplicatesAndMovesToFront() throws {
        let store = makeStore()
        let first = URL(fileURLWithPath: "/tmp/one.md")
        let second = URL(fileURLWithPath: "/tmp/two.md")

        try store.add(first, at: Date(timeIntervalSince1970: 1))
        try store.add(second, at: Date(timeIntervalSince1970: 2))
        let documents = try store.add(first, at: Date(timeIntervalSince1970: 3))

        XCTAssertEqual(documents.map(\.path), [first.path, second.path])
        XCTAssertEqual(store.load().map(\.displayName), ["one.md", "two.md"])
    }

    func testRecentIsCappedAtTen() throws {
        let store = makeStore()
        for index in 0..<14 {
            try store.add(URL(fileURLWithPath: "/tmp/file-\(index).md"))
        }
        let documents = store.load()
        XCTAssertEqual(documents.count, RecentDocumentsStore.maximumCount)
        XCTAssertEqual(documents.first?.displayName, "file-13.md")
    }

    func testRecentRemoveAndClear() throws {
        let store = makeStore()
        let url = URL(fileURLWithPath: "/tmp/one.md")
        try store.add(url)
        XCTAssertEqual(try store.remove(path: url.standardizedFileURL.path).count, 0)
        try store.add(url)
        store.clear()
        XCTAssertTrue(store.load().isEmpty)
    }

    func testSessionRestorationRoundTripKeepsOrderAndDeduplicates() throws {
        let store = SessionRestorationStore(fileURL: tempDirectory.appendingPathComponent("Open.json"))
        let one = tempDirectory.appendingPathComponent("one.md")
        let two = tempDirectory.appendingPathComponent("two.md")
        try Data("one".utf8).write(to: one)
        try Data("two".utf8).write(to: two)
        try store.save([one, two, one])

        XCTAssertEqual(store.load().map(\.lastPathComponent), ["one.md", "two.md"])
    }

    func testSessionRestorationMissingFileIsDropped() throws {
        let store = SessionRestorationStore(fileURL: tempDirectory.appendingPathComponent("Open.json"))
        let missing = tempDirectory.appendingPathComponent("gone.md")
        let present = tempDirectory.appendingPathComponent("here.md")
        try Data("x".utf8).write(to: present)

        try store.save([missing, present])
        XCTAssertEqual(store.load().map(\.lastPathComponent), ["here.md"])
    }
}

final class DocumentDirtyStateTests: XCTestCase {
    func testNewDocumentIsClean() {
        let state = DocumentDirtyState()
        XCTAssertFalse(state.isDirty)
        XCTAssertEqual(state.displayName, "Untitled")
    }

    func testEditingMarksDirtyAndSavingClearsIt() {
        var state = DocumentDirtyState()
        state.edit("hello")
        XCTAssertTrue(state.isDirty)
        state.markSaved()
        XCTAssertFalse(state.isDirty)
        XCTAssertEqual(state.savedText, "hello")
    }

    func testUnchangedEditDoesNotDirty() {
        var state = DocumentDirtyState()
        XCTAssertFalse(state.edit(""))
    }

    func testLoadResetsBaselineAndURL() {
        var state = DocumentDirtyState()
        let url = URL(fileURLWithPath: "/tmp/note.md")
        state.load(text: "content", fileURL: url)
        XCTAssertFalse(state.isDirty)
        XCTAssertEqual(state.displayName, "note.md")
    }

    func testMarkSavedAtNewURLClearsDirty() {
        var state = DocumentDirtyState()
        state.edit("draft")
        let url = URL(fileURLWithPath: "/tmp/draft.md")
        state.markSaved(at: url)
        XCTAssertFalse(state.isDirty)
        XCTAssertEqual(state.fileURL, url)
    }

    func testRevertRestoresSavedText() {
        var state = DocumentDirtyState(text: "saved")
        state.edit("changed")
        state.revert()
        XCTAssertEqual(state.text, "saved")
        XCTAssertFalse(state.isDirty)
    }
}
