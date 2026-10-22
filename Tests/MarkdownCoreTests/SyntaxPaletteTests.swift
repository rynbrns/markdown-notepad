import XCTest
@testable import MarkdownCore

final class SyntaxPaletteTests: XCTestCase {
    private var kinds: [MarkdownSyntaxSpan.Kind] {
        [
            .heading(level: 1), .heading(level: 6), .emphasis, .strong, .strikethrough,
            .listMarker, .taskMarker, .link, .image, .codeSpan, .codeBlock,
            .tableHeader, .tableDelimiter, .tableRow, .blockQuote
        ]
    }

    func testEverySyntaxColourMeetsWCAGAAInLightMode() {
        for kind in kinds {
            let color = SyntaxPalette.color(for: kind, dark: false)
            let ratio = color.contrastRatio(with: SyntaxPalette.standardLightBackground)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(kind) light contrast was \(ratio)")
        }
    }

    func testEverySyntaxColourMeetsWCAGAAInDarkMode() {
        for kind in kinds {
            let color = SyntaxPalette.color(for: kind, dark: true)
            let ratio = color.contrastRatio(with: SyntaxPalette.standardDarkBackground)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(kind) dark contrast was \(ratio)")
        }
    }

    func testContrastFormulaMatchesKnownValues() {
        let black = SyntaxPalette.RGB(red: 0, green: 0, blue: 0)
        let white = SyntaxPalette.RGB(red: 1, green: 1, blue: 1)
        XCTAssertEqual(black.contrastRatio(with: white), 21, accuracy: 0.01)
        XCTAssertEqual(white.contrastRatio(with: white), 1, accuracy: 0.01)
    }
}
