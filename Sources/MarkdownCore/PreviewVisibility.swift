import Foundation

/// Pure policy for whether the split preview opens by default.
///
/// The window-facing code lives in the app target; this tiny rule is kept in
/// `MarkdownCore` so it can be unit-tested on Linux and quoted by the UI.
public enum PreviewVisibility {
    /// Windows wider than this many points open with the preview visible.
    public static let defaultMinimumWidth: Double = 900

    public static func shouldShowByDefault(windowWidth: Double) -> Bool {
        windowWidth > defaultMinimumWidth
    }
}
