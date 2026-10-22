import Foundation
import XCTest
@testable import MarkdownCore

final class FindEngineTests: XCTestCase {
    func testLiteralSearchIsCaseInsensitiveByDefault() throws {
        let matches = try FindEngine.matches(of: "needle", in: "Needle needle NEEDLE")
        XCTAssertEqual(matches.count, 3)
        XCTAssertEqual(matches.map(\.text), ["Needle", "needle", "NEEDLE"])
    }

    func testCaseSensitiveSearch() throws {
        let matches = try FindEngine.matches(
            of: "needle",
            in: "Needle needle NEEDLE",
            options: FindOptions(caseSensitive: true)
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].range, NSRange(location: 7, length: 6))
    }

    func testEmptyQueryHasNoMatches() throws {
        XCTAssertTrue(try FindEngine.matches(of: "", in: "anything").isEmpty)
    }

    func testRegexSearchAndInvalidPattern() throws {
        let matches = try FindEngine.matches(
            of: "\\bcat\\b",
            in: "cat concatenate cat",
            options: FindOptions(usesRegularExpression: true)
        )
        XCTAssertEqual(matches.count, 2)

        XCTAssertThrowsError(
            try FindEngine.matches(
                of: "(",
                in: "text",
                options: FindOptions(usesRegularExpression: true)
            )
        ) { error in
            guard case FindError.invalidRegularExpression = error else {
                return XCTFail("Expected invalidRegularExpression, got \(error)")
            }
        }
    }

    func testMatchesAreNonOverlapping() throws {
        let matches = try FindEngine.matches(of: "aa", in: "aaaaa")
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches.map(\.range), [
            NSRange(location: 0, length: 2),
            NSRange(location: 2, length: 2)
        ])
    }

    func testReplaceAllLiteralPreservesCaseOfOtherMatches() throws {
        let result = try FindEngine.replacingAll(in: "Cat cat CAT", query: "cat", replacement: "dog")
        XCTAssertEqual(result, "dog dog dog")
    }

    func testReplaceAllRegexTemplate() throws {
        let result = try FindEngine.replacingAll(
            in: "first last\nsecond person",
            query: "(\\w+) (\\w+)",
            replacement: "$2 $1",
            options: FindOptions(usesRegularExpression: true)
        )
        XCTAssertEqual(result, "last first\nperson second")
    }

    func testReplaceSingleMatch() throws {
        let matches = try FindEngine.matches(of: "x", in: "x x x")
        let result = FindEngine.replacing(match: matches[1], in: "x x x", with: "y")
        XCTAssertEqual(result, "x y x")
    }

    func testNearestMatchIndex() throws {
        let matches = try FindEngine.matches(of: "a", in: "a__a__a")
        XCTAssertEqual(FindEngine.matchIndex(nearest: 0, in: matches), 0)
        XCTAssertEqual(FindEngine.matchIndex(nearest: 1, in: matches), 1)
        XCTAssertEqual(FindEngine.matchIndex(nearest: 7, in: matches), 2)
        XCTAssertNil(FindEngine.matchIndex(nearest: 0, in: []))
    }
}
