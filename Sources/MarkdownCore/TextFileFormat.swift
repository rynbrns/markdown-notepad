import Foundation

/// The line terminator used by a text file.
public enum LineEnding: String, Equatable, Sendable, Codable, CaseIterable {
    /// Unix style `\n`.
    case lf
    /// Windows style `\r\n`.
    case crlf
    /// Classic Mac style `\r`.
    case cr
    /// More than one terminator style in the same file.
    case mixed
    /// No line terminators at all.
    case none

    /// Human-readable label for the status bar and diagnostics.
    public var label: String {
        switch self {
        case .lf: return "LF"
        case .crlf: return "CRLF"
        case .cr: return "CR"
        case .mixed: return "Mixed line endings"
        case .none: return "No line endings"
        }
    }

    /// The literal bytes (as a string) for this terminator.
    public var sequence: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        case .mixed, .none: return "\n"
        }
    }
}

/// The on-disk format details that must survive a round trip.
///
/// `lineEnding` is the summary shown to the user; `originalLineEndings` records
/// the terminator of every original line so an untouched file can be written
/// back byte for byte, including files that mix styles.
public struct TextFileFormat: Equatable, Sendable, Codable {
    /// True when the file starts with a UTF-8 byte-order mark (EF BB BF).
    public var hasBOM: Bool
    /// The summary line-ending style.
    public var lineEnding: LineEnding
    /// One entry per original line break, in order. Empty when `lineEnding == .none`.
    public var originalLineEndings: [LineEnding]

    public init(
        hasBOM: Bool = false,
        lineEnding: LineEnding = .lf,
        originalLineEndings: [LineEnding] = []
    ) {
        self.hasBOM = hasBOM
        self.lineEnding = lineEnding
        self.originalLineEndings = originalLineEndings
    }

    /// The terminator to use for newly added lines.
    public var dominantLineEnding: LineEnding {
        switch lineEnding {
        case .lf, .crlf, .cr: return lineEnding
        case .none: return .lf
        case .mixed:
            var counts: [LineEnding: Int] = [:]
            for ending in originalLineEndings {
                counts[ending, default: 0] += 1
            }
            let ranked = counts.sorted { lhs, rhs in
                if lhs.value == rhs.value { return sortRank(lhs.key) < sortRank(rhs.key) }
                return lhs.value > rhs.value
            }
            return ranked.first?.key ?? .lf
        }
    }

    private func sortRank(_ ending: LineEnding) -> Int {
        LineEnding.allCases.firstIndex(of: ending) ?? 0
    }

    /// A short description suitable for a status line.
    public var label: String {
        var parts: [String] = []
        parts.append("UTF-8")
        if hasBOM { parts.append("BOM") }
        parts.append(lineEnding.label)
        return parts.joined(separator: " · ")
    }
}
