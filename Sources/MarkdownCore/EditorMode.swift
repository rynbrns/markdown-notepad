import Foundation

/// The three ways the editor can present the same Markdown document.
///
/// The raw text (`DocumentSession.text`, which is also what gets saved) never
/// changes when the mode changes; the mode only controls how that text is
/// displayed. Persisted values are stable strings so a future mode can be added
/// without invalidating an existing preference file.
public enum EditorMode: String, CaseIterable, Codable, Hashable, Sendable {
    /// Raw Markdown source with syntax colouring and no preview.
    case plainText
    /// Source editor plus the rendered GFM preview (the M3 split view).
    case panels
    /// Rendered rich text with Markdown markers hidden while editing.
    case wysiwyg

    public var title: String {
        switch self {
        case .plainText:
            return "Plain Text"
        case .panels:
            return "Panels"
        case .wysiwyg:
            return "WYSIWYG"
        }
    }

    public var summary: String {
        switch self {
        case .plainText:
            return "Raw Markdown source, no preview."
        case .panels:
            return "Source editor beside a live rendered preview."
        case .wysiwyg:
            return "Rendered text with Markdown markers hidden."
        }
    }

    /// The mode used when no preference has been stored yet.
    public static let fallback: EditorMode = .plainText
}

/// Durable, single-value preference for the editor mode.
///
/// The last mode the user chooses becomes the default for new windows and for
/// the next launch. Only the chosen mode is persisted; a missing or unreadable
/// file falls back to ``EditorMode/fallback`` rather than failing launch.
public struct EditorModeStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Default location: `~/Library/Application Support/MarkdownNotepad/EditorMode.json`.
    public static func defaultFileURL() -> URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("MarkdownNotepad", isDirectory: true)
            .appendingPathComponent("EditorMode.json")
    }

    /// The stored mode, or `nil` when the file is absent or invalid.
    public func load() -> EditorMode? {
        guard let data = try? Data(contentsOf: fileURL),
              let mode = try? JSONDecoder().decode(EditorMode.self, from: data),
              EditorMode.allCases.contains(mode) else { return nil }
        return mode
    }

    public func save(_ mode: EditorMode) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(mode)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try AtomicFileWriter.write(data, to: fileURL)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
