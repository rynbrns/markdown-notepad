import Foundation
import XCTest
@testable import MarkdownCore

final class TextFileFormatTests: XCTestCase {
    private let roundTripFixtures = [
        "lf", "crlf", "cr", "bom_lf", "bom_crlf",
        "mixed", "unicode", "no_eol", "empty", "bom_only", "single_line"
    ]

    func testByteForByteRoundTripOfEveryGoldenFile() throws {
        for name in roundTripFixtures {
            let original = Fixtures.data(name)
            let decoded = try TextFile.decode(original)
            let reencoded = decoded.encodedBytes()
            XCTAssertEqual(
                reencoded,
                original,
                "\(name).md did not round-trip byte for byte"
            )
        }
    }

    func testLineEndingDetection() throws {
        let expectations: [String: LineEnding] = [
            "lf": .lf,
            "crlf": .crlf,
            "cr": .cr,
            "bom_lf": .lf,
            "bom_crlf": .crlf,
            "mixed": .mixed,
            "unicode": .mixed,
            "no_eol": .none,
            "empty": .none,
            "bom_only": .none,
            "single_line": .lf
        ]

        for (name, expected) in expectations {
            let decoded = try TextFile.decode(Fixtures.data(name))
            XCTAssertEqual(decoded.format.lineEnding, expected, "\(name).md line ending")
        }
    }

    func testBOMPreserved() throws {
        let withBOM = try TextFile.decode(Fixtures.data("bom_lf"))
        XCTAssertTrue(withBOM.format.hasBOM)
        XCTAssertTrue(withBOM.encodedBytes().starts(with: [0xEF, 0xBB, 0xBF]))

        let withoutBOM = try TextFile.decode(Fixtures.data("lf"))
        XCTAssertFalse(withoutBOM.format.hasBOM)
    }

    func testBOMOnlyFile() throws {
        let decoded = try TextFile.decode(Fixtures.data("bom_only"))
        XCTAssertTrue(decoded.format.hasBOM)
        XCTAssertEqual(decoded.text, "")
        XCTAssertEqual(decoded.encodedBytes(), Data([0xEF, 0xBB, 0xBF]))
    }

    func testTextIsNormalizedToLFForEditing() throws {
        let decoded = try TextFile.decode(Fixtures.data("mixed"))
        XCTAssertEqual(decoded.text, "first\nsecond\nthird\nfourth")
        XCTAssertEqual(decoded.format.originalLineEndings, [.crlf, .lf, .crlf])
    }

    func testUnicodeContentSurvives() throws {
        let decoded = try TextFile.decode(Fixtures.data("unicode"))
        XCTAssertTrue(decoded.text.contains("café"))
        XCTAssertTrue(decoded.text.contains("😀"))
        XCTAssertTrue(decoded.text.contains("漢字"))
        XCTAssertTrue(decoded.text.contains("🎉"))
    }

    func testEditedCRLFDocumentKeepsCRLF() throws {
        var decoded = try TextFile.decode(Fixtures.data("crlf"))
        decoded.text = "Hello, world.\nSecond line.\nThird added line.\n"
        XCTAssertEqual(
            decoded.encodedBytes(),
            Data("Hello, world.\r\nSecond line.\r\nThird added line.\r\n".utf8)
        )
    }

    func testEditedLFDocumentStaysLF() throws {
        var decoded = try TextFile.decode(Fixtures.data("lf"))
        decoded.text = "a\nb\nc\n"
        XCTAssertEqual(decoded.encodedBytes(), Data("a\nb\nc\n".utf8))
    }

    func testEditedMixedDocumentPreservesOriginalLinesAndUsesDominantEnding() throws {
        var decoded = try TextFile.decode(Fixtures.data("mixed"))
        decoded.text = "first\nsecond\nthird\nfourth\nfifth"
        XCTAssertEqual(
            decoded.encodedBytes(),
            Data("first\r\nsecond\nthird\r\nfourth\r\nfifth".utf8)
        )
    }

    func testEditedClassicMacDocumentKeepsCR() throws {
        var decoded = try TextFile.decode(Fixtures.data("cr"))
        decoded.text = "a\nb\n"
        XCTAssertEqual(decoded.encodedBytes(), Data("a\rb\r".utf8))
    }

    func testNoTrailingNewlineIsNotInvented() throws {
        var decoded = try TextFile.decode(Fixtures.data("no_eol"))
        XCTAssertEqual(decoded.encodedBytes(), Data("no trailing newline".utf8))
        decoded.text = "no trailing newline\n"
        XCTAssertEqual(decoded.encodedBytes(), Data("no trailing newline\n".utf8))
    }

    func testInvalidUTF8IsRejectedWithoutLoss() {
        let invalid = Data([0x48, 0x65, 0xFF, 0xFE, 0x6C, 0x6F])
        XCTAssertThrowsError(try TextFile.decode(invalid)) { error in
            XCTAssertEqual(error as? MarkdownCoreError, .notUTF8)
        }
    }

    func testTruncatedMultibyteUTF8IsRejected() {
        let truncated = Data([0xE6, 0xBC]) // first two bytes of 漢
        XCTAssertThrowsError(try TextFile.decode(truncated)) { error in
            XCTAssertEqual(error as? MarkdownCoreError, .notUTF8)
        }
    }

    func testFormatLabelMentionsBOMAndLineEnding() {
        let format = TextFileFormat(hasBOM: true, lineEnding: .mixed, originalLineEndings: [.lf, .crlf])
        XCTAssertEqual(format.label, "UTF-8 · BOM · Mixed line endings")
    }

    func testDominantLineEndingForMixed() {
        let format = TextFileFormat(
            hasBOM: false,
            lineEnding: .mixed,
            originalLineEndings: [.crlf, .lf, .crlf, .crlf]
        )
        XCTAssertEqual(format.dominantLineEnding, .crlf)
    }
}
