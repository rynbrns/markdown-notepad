import Foundation

/// Accessible foreground colours for Markdown syntax categories.
///
/// The values are explicit sRGB pairs (light/dark) rather than system colours,
/// because several of the system accent colours fail WCAG AA contrast against
/// the editor background in one appearance or the other. `SyntaxPaletteTests`
/// asserts every pair reaches at least 4.5:1 against the standard light and dark
/// text backgrounds.
public enum SyntaxPalette {
    public struct RGB: Equatable, Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        init(hex: String) {
            var value: UInt64 = 0
            Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
            self.red = Double((value >> 16) & 0xFF) / 255
            self.green = Double((value >> 8) & 0xFF) / 255
            self.blue = Double(value & 0xFF) / 255
        }

        /// WCAG 2.1 relative luminance.
        public var relativeLuminance: Double {
            func linear(_ component: Double) -> Double {
                component <= 0.04045
                    ? component / 12.92
                    : pow((component + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        /// WCAG 2.1 contrast ratio between two colours.
        public func contrastRatio(with other: RGB) -> Double {
            let first = relativeLuminance
            let second = other.relativeLuminance
            return (max(first, second) + 0.05) / (min(first, second) + 0.05)
        }
    }

    public static let standardLightBackground = RGB(hex: "#FFFFFF")
    public static let standardDarkBackground = RGB(hex: "#1E1E1E")

    public static func color(for kind: MarkdownSyntaxSpan.Kind, dark: Bool) -> RGB {
        let hex: String
        switch kind {
        case .heading, .link, .image:
            hex = dark ? "#8AB4F8" : "#0B57D0"
        case .emphasis:
            hex = dark ? "#D7B8FF" : "#6B21A8"
        case .strong:
            hex = dark ? "#FFB4AB" : "#B3261E"
        case .strikethrough, .blockQuote:
            hex = dark ? "#BDC1C6" : "#5F6368"
        case .listMarker:
            hex = dark ? "#80CBC4" : "#00695C"
        case .taskMarker:
            hex = dark ? "#A5D6A7" : "#1E6B2E"
        case .codeSpan, .codeBlock:
            hex = dark ? "#FFB1C8" : "#A31545"
        case .tableHeader, .tableDelimiter, .tableRow:
            hex = dark ? "#C5C0FF" : "#3F3B9E"
        }
        return RGB(hex: hex)
    }
}
