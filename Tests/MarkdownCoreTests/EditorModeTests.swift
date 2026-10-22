import Foundation
import XCTest
@testable import MarkdownCore

final class EditorModeTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = try makeTempDirectory()
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            removeTempDirectory(tempDirectory)
        }
    }

    private func makeStore() -> EditorModeStore {
        EditorModeStore(fileURL: tempDirectory.appendingPathComponent("EditorMode.json"))
    }

    func testDefaultFileURLPointsAtTheSupportDirectory() {
        let url = EditorModeStore.defaultFileURL()
        XCTAssertEqual(url.lastPathComponent, "EditorMode.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "MarkdownNotepad")
    }

    func testMissingFileHasNoStoredMode() {
        XCTAssertNil(makeStore().load())
    }

    func testEveryModeRoundTrips() throws {
        let store = makeStore()
        for mode in EditorMode.allCases {
            try store.save(mode)
            XCTAssertEqual(store.load(), mode)
        }
    }

    func testInvalidFileFallsBackToNoPreference() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        try Data("not a mode".utf8).write(to: store.fileURL)
        XCTAssertNil(store.load())
        XCTAssertEqual(EditorMode.fallback, .plainText)
    }

    func testClearRemovesThePreference() throws {
        let store = makeStore()
        try store.save(.wysiwyg)
        XCTAssertEqual(store.load(), .wysiwyg)
        store.clear()
        XCTAssertNil(store.load())
    }

    func testTitlesAreDistinct() {
        let titles = Set(EditorMode.allCases.map(\.title))
        XCTAssertEqual(titles.count, EditorMode.allCases.count)
    }
}
