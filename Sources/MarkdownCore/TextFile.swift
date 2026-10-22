import Foundation

/// A decoded text file: normalized editing text plus everything needed to write
/// it back without disturbing untouched bytes.
///
/// `text` always uses `\n` line endings so the editor and tests have one
/// canonical representation. `format` remembers the BOM and the original
/// terminator of every line, so `decode` → `encode` with no edits is
/// byte-for-byte identical, including mixed-line-ending files.
public struct TextFile: Equatable, Sendable {
    /// Text with `\n` line endings and no BOM.
    public var text: String
    /// How the source was encoded on disk.
    public var format: TextFileFormat

    public init(text: String, format: TextFileFormat = TextFileFormat()) {
        self.text = text
        self.format = format
    }

    private static let bomBytes: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// Decodes UTF-8 bytes, preserving BOM and line-ending metadata.
    ///
    /// Throws `MarkdownCoreError.notUTF8` for invalid UTF-8; the input bytes are
    /// never altered.
    public static func decode(_ data: Data) throws -> TextFile {
        let bytes = [UInt8](data)
        let hasBOM = bytes.count >= 3 && Array(bytes.prefix(3)) == bomBytes
        let bodyStart = hasBOM ? 3 : 0
        let body = Data(bytes[bodyStart...])

        guard let rawText = String(data: body, encoding: .utf8) else {
            throw MarkdownCoreError.notUTF8
        }

        let scanned = scanLineEndings(in: rawText)
        let summary: LineEnding
        let unique = Set(scanned.endings)
        if unique.isEmpty {
            summary = .none
        } else if unique.count == 1 {
            summary = unique.first!
        } else {
            summary = .mixed
        }

        let format = TextFileFormat(
            hasBOM: hasBOM,
            lineEnding: summary,
            originalLineEndings: scanned.endings
        )
        return TextFile(text: scanned.normalized, format: format)
    }

    /// Encodes the current text using the remembered BOM and line endings.
    ///
    /// Unchanged lines keep their original terminator. Lines added by the user
    /// use the dominant terminator. A file that started with no terminators
    /// gains `\n` only if the user actually typed a line break.
    public func encodedBytes() -> Data {
        let pieces = text.components(separatedBy: "\n")
        var output = ""
        output.reserveCapacity(text.count + pieces.count)

        for (index, piece) in pieces.enumerated() {
            output.append(piece)
            guard index < pieces.count - 1 else { continue }
            let ending = originalEnding(at: index) ?? format.dominantLineEnding
            output.append(ending.sequence)
        }

        var bytes = [UInt8](output.utf8)
        if format.hasBOM {
            bytes.insert(contentsOf: TextFile.bomBytes, at: 0)
        }
        return Data(bytes)
    }

    private func originalEnding(at index: Int) -> LineEnding? {
        guard index < format.originalLineEndings.count else { return nil }
        let ending = format.originalLineEndings[index]
        switch ending {
        case .lf, .crlf, .cr: return ending
        case .mixed, .none: return nil
        }
    }

    /// Normalizes a raw string and records one ending per line break.
    private static func scanLineEndings(in text: String) -> (normalized: String, endings: [LineEnding]) {
        var normalized = String()
        normalized.reserveCapacity(text.count)
        var endings: [LineEnding] = []

        var index = text.unicodeScalars.startIndex
        let scalars = text.unicodeScalars
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == "\r" {
                let next = scalars.index(after: index)
                if next < scalars.endIndex && scalars[next] == "\n" {
                    endings.append(.crlf)
                    index = scalars.index(after: next)
                } else {
                    endings.append(.cr)
                    index = next
                }
                normalized.unicodeScalars.append("\n")
            } else if scalar == "\n" {
                endings.append(.lf)
                normalized.unicodeScalars.append("\n")
                index = scalars.index(after: index)
            } else {
                normalized.unicodeScalars.append(scalar)
                index = scalars.index(after: index)
            }
        }

        return (normalized, endings)
    }
}
