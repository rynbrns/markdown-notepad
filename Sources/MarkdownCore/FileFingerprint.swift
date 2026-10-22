import Foundation

/// A cheap identity for a file's contents at a moment in time.
///
/// The digest is authoritative; size and modification time are kept for
/// diagnostics and for the recovery snapshot. A save compares the current
/// fingerprint against the baseline captured when the file was opened, so an
/// external edit is never overwritten silently.
public struct FileFingerprint: Equatable, Sendable, Codable {
    public let byteCount: Int
    public let modificationTime: TimeInterval?
    public let sha256: String

    public init(byteCount: Int, modificationTime: TimeInterval?, sha256: String) {
        self.byteCount = byteCount
        self.modificationTime = modificationTime
        self.sha256 = sha256
    }

    /// Two fingerprints represent the same content when their digests and sizes
    /// match. Modification time is deliberately excluded so touching a file
    /// without changing bytes does not raise a false conflict.
    public func hasSameContent(as other: FileFingerprint) -> Bool {
        sha256 == other.sha256 && byteCount == other.byteCount
    }

    /// Captures the fingerprint for an existing file, or `nil` when it does not exist.
    public static func capture(at url: URL) throws -> FileFingerprint? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw FileSystemError.map(error, url: url)
        }

        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let modification = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970
        return FileFingerprint(
            byteCount: data.count,
            modificationTime: modification,
            sha256: SHA256.hexDigest(of: data)
        )
    }
}
