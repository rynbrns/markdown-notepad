import XCTest
@testable import MarkdownCore

final class PreviewVisibilityTests: XCTestCase {
    func testWideWindowsOpenPreview() {
        XCTAssertTrue(PreviewVisibility.shouldShowByDefault(windowWidth: 901))
        XCTAssertTrue(PreviewVisibility.shouldShowByDefault(windowWidth: 1440))
    }

    func testNarrowAndBoundaryWindowsStaySinglePane() {
        XCTAssertFalse(PreviewVisibility.shouldShowByDefault(windowWidth: 900))
        XCTAssertFalse(PreviewVisibility.shouldShowByDefault(windowWidth: 640))
        XCTAssertFalse(PreviewVisibility.shouldShowByDefault(windowWidth: 0))
    }
}
