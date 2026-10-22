import Foundation

/// An in-memory plain-text markdown document.
///
/// This type is intentionally free of UI and file-system concerns so it can be
/// built and tested on Linux. File loading/saving arrives in M1; for now this is
/// the shared model that the macOS app consumes.
public struct MarkdownDocument: Equatable, Sendable {
    public var text: String

    public init(text: String = "") {
        self.text = text
    }

    /// Number of UTF-8 bytes in the document.
    public var utf8ByteCount: Int {
        text.utf8.count
    }

    /// Number of display lines. An empty document has zero lines; a trailing
    /// newline starts a new (empty) line.
    public var lineCount: Int {
        guard !text.isEmpty else { return 0 }
        return text.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        }
    }

    /// Number of whitespace-separated words.
    public var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// True when the document contains no characters at all.
    public var isEmpty: Bool {
        text.isEmpty
    }

    /// True when the document contains only whitespace (including empty).
    public var isBlank: Bool {
        text.allSatisfy { $0.isWhitespace }
    }

    /// Document statistics used by the app status bar.
    public var statistics: DocumentStatistics {
        DocumentStatistics(
            lineCount: lineCount,
            wordCount: wordCount,
            utf8ByteCount: utf8ByteCount
        )
    }
}

/// Derived measurements for a document.
public struct DocumentStatistics: Equatable, Sendable {
    public let lineCount: Int
    public let wordCount: Int
    public let utf8ByteCount: Int

    public init(lineCount: Int, wordCount: Int, utf8ByteCount: Int) {
        self.lineCount = lineCount
        self.wordCount = wordCount
        self.utf8ByteCount = utf8ByteCount
    }
}
