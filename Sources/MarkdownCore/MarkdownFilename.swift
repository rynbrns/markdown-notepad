import Foundation

/// Filename rules for the markdown notepad's inline title-bar rename.
///
/// The editor only writes `.md` documents, so a user-supplied name is always
/// normalized to a single, visible filename ending in `.md`. The rules are
/// intentionally conservative: anything that could escape the chosen folder or
/// produce an unusable name is rejected rather than silently rewritten.
public enum MarkdownFilename {
    public static let markdownExtension = "md"

    /// Returns a safe single-component filename ending in `.md`, or `nil` when
    /// the proposed name cannot be used.
    ///
    /// - Trims surrounding whitespace.
    /// - Rejects empty names, `.`, `..`, path separators, and control characters.
    /// - Keeps an existing `.md` suffix (any casing); otherwise appends `.md`.
    ///   For example `notes` becomes `notes.md` and `notes.txt` becomes
    ///   `notes.txt.md` so no part of the user's text is dropped.
    public static func normalized(_ proposedName: String) -> String? {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return nil }
        guard !trimmed.hasPrefix(".") else { return nil }
        guard !trimmed.contains("/"), !trimmed.contains(":") else { return nil }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        guard !trimmed.hasSuffix(".") else { return nil }

        if (trimmed as NSString).pathExtension.caseInsensitiveCompare(markdownExtension) == .orderedSame {
            return trimmed
        }
        return "\(trimmed).\(markdownExtension)"
    }

    /// The editable stem shown in the title bar (`.md` removed when present).
    public static func editableName(for filename: String) -> String {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmed as NSString).pathExtension.caseInsensitiveCompare(markdownExtension) == .orderedSame else {
            return trimmed
        }
        let stem = (trimmed as NSString).deletingPathExtension
        return stem.isEmpty ? trimmed : stem
    }

    /// True when both URLs point at the same file after standardizing.
    public static func isSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }
}
