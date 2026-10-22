import Foundation

/// A crash-recovery snapshot of an unsaved document.
public struct RecoverySnapshot: Equatable, Sendable, Codable {
    /// Stable identifier for the document (derived from its path, or a UUID for untitled).
    public let documentID: String
    /// Original file path, when the document has one.
    public let fileURL: String?
    /// Normalized editing text (`\n` line endings, no BOM).
    public let text: String
    /// BOM/line-ending format to re-apply if the snapshot is restored.
    public let format: TextFileFormat
    /// Fingerprint of the file when it was opened, used to detect edits after a crash.
    public let baseline: FileFingerprint?
    /// When the snapshot was taken.
    public let savedAt: Date

    public init(
        documentID: String,
        fileURL: String?,
        text: String,
        format: TextFileFormat,
        baseline: FileFingerprint?,
        savedAt: Date = Date()
    ) {
        self.documentID = documentID
        self.fileURL = fileURL
        self.text = text
        self.format = format
        self.baseline = baseline
        self.savedAt = savedAt
    }

    /// The snapshot as an editable text file.
    public var textFile: TextFile {
        TextFile(text: text, format: format)
    }
}

/// Durable store for unsaved-document snapshots.
///
/// Lives under Application Support (never in the user's document folder). Each
/// snapshot is written atomically, so a crash during snapshotting cannot leave
/// a half-written recovery file. The store is re-runnable and `save` is
/// idempotent for the same document.
public struct RecoveryStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Default location: `~/Library/Application Support/MarkdownNotepad/Recovery`
    /// (or the platform Application Support equivalent).
    public static func defaultDirectory() -> URL {
        let fileManager = FileManager.default
        if let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return base
                .appendingPathComponent("MarkdownNotepad", isDirectory: true)
                .appendingPathComponent("Recovery", isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("MarkdownNotepad", isDirectory: true)
            .appendingPathComponent("Recovery", isDirectory: true)
    }

    /// Stable document identifier for a file-backed document.
    public static func documentID(for url: URL) -> String {
        "file-\(SHA256.hexDigest(of: Data(url.standardizedFileURL.path.utf8)))"
    }

    /// Stable document identifier for an untitled document.
    public static func documentID(forUntitled id: UUID) -> String {
        "untitled-\(id.uuidString.lowercased())"
    }

    /// Writes (or replaces) the snapshot for its document.
    public func save(_ snapshot: RecoverySnapshot) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try AtomicFileWriter.write(data, to: fileURL(for: snapshot.documentID))
    }

    /// Returns the snapshot for a document, or `nil` when none exists.
    public func load(documentID: String) throws -> RecoverySnapshot? {
        let url = fileURL(for: documentID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw FileSystemError.map(error, url: url)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(RecoverySnapshot.self, from: data)
        } catch {
            return nil
        }
    }

    /// Returns the snapshot for a file-backed document, or `nil`.
    public func load(for url: URL) throws -> RecoverySnapshot? {
        try load(documentID: RecoveryStore.documentID(for: url))
    }

    /// Removes the snapshot after a clean save or quit. Missing files are fine.
    public func delete(documentID: String) throws {
        let url = fileURL(for: documentID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw FileSystemError.map(error, url: url)
        }
    }

    public func delete(for url: URL) throws {
        try delete(documentID: RecoveryStore.documentID(for: url))
    }

    /// All readable snapshots currently on disk, newest first.
    public func loadAll() throws -> [RecoverySnapshot] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return [] }

        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            throw FileSystemError.map(error, url: directory)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var snapshots: [RecoverySnapshot] = []
        for url in contents where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? decoder.decode(RecoverySnapshot.self, from: data) else {
                continue
            }
            snapshots.append(snapshot)
        }
        return snapshots.sorted { $0.savedAt > $1.savedAt }
    }

    /// Deletes every snapshot, used after a clean quit.
    public func deleteAll() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            throw FileSystemError.map(error, url: directory)
        }
        for url in contents where url.pathExtension == "json" {
            try? fileManager.removeItem(at: url)
        }
    }

    private func fileURL(for documentID: String) -> URL {
        directory.appendingPathComponent("\(documentID).json")
    }

    private func ensureDirectory() throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                throw MarkdownCoreError.ioFailure("The recovery path is not a folder.")
            }
            return
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw FileSystemError.map(error, url: directory)
        }
    }
}
