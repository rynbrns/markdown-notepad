import AppKit
import MarkdownCore

/// Bridges the Foundation-only ``SyntaxPalette`` into AppKit dynamic colours
/// that follow the system appearance.
enum MarkdownSyntaxPalette {
    static func color(for kind: MarkdownSyntaxSpan.Kind) -> NSColor {
        let light = SyntaxPalette.color(for: kind, dark: false)
        let dark = SyntaxPalette.color(for: kind, dark: true)
        return NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return nsColor(match == .darkAqua ? dark : light)
        }
    }

    static func nsColor(_ rgb: SyntaxPalette.RGB) -> NSColor {
        NSColor(
            srgbRed: CGFloat(rgb.red),
            green: CGFloat(rgb.green),
            blue: CGFloat(rgb.blue),
            alpha: 1
        )
    }
}
