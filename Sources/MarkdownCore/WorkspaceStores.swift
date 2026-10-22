import Foundation

/// One entry in the File > Open Recent list.
public struct RecentDocument: Codable, Equatable, Sendable {
    public let path: String
    public let displayName: String
    public let openedAt: Date

    public init(url: URL, openedAt: Date = Date()) {
        self.path = url.standardizedFileURL.path
        self.displayName = url.lastPathComponent
        self.openedAt = openedAt
    }

    public var url: URL {
        URL(fileURLWithPath: path)
    }
}

/// Durable, idempotent recent-documents list.
///
/// The list is capped at `maximumCount` (10 by default) and de-duplicated by
/// standardized path. Writing a URL that is already present moves it to the
/// front instead of adding a duplicate. A missing file stays on the list until
/// the user clears it; the UI greys it out.
public struct RecentDocumentsStore: Sendable {
    public static let maximumCount = 10

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Default location: `~/Library/Application Support/MarkdownNotepad/RecentDocuments.json`.
    public static func defaultFileURL() -> URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("MarkdownNotepad", isDirectory: true)
            .appendingPathComponent("RecentDocuments.json")
    }

    public func load() -> [RecentDocument] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let documents = try? decoder.decode([RecentDocument].self, from: data) else { return [] }
        return Array(documents.prefix(Self.maximumCount))
    }

    public func save(_ documents: [RecentDocument]) throws {
        let trimmed = Array(documents.prefix(Self.maximumCount))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(trimmed)
        try ensureParentDirectory()
        try AtomicFileWriter.write(data, to: fileURL)
    }

    /// Adds `url` to the front of the list, removing any previous entry with
    /// the same standardized path, and persists the result.
    @discardableResult
    public func add(_ url: URL, at date: Date = Date()) throws -> [RecentDocument] {
        let entry = RecentDocument(url: url, openedAt: date)
        var documents = load().filter { $0.path != entry.path }
        documents.insert(entry, at: 0)
        documents = Array(documents.prefix(Self.maximumCount))
        try save(documents)
        return documents
    }

    @discardableResult
    public func remove(path: String) throws -> [RecentDocument] {
        let documents = load().filter { $0.path != path }
        try save(documents)
        return documents
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func ensureParentDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

/// Persists the files that were open when the app last quit, so the next launch
/// can restore the workspace.
///
/// Only file-backed documents are restorable; untitled documents already have
/// a crash-recovery snapshot and are handled by `RecoveryStore`.
public struct SessionRestorationStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL() -> URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("MarkdownNotepad", isDirectory: true)
            .appendingPathComponent("OpenDocuments.json")
    }

    /// Standardized, de-duplicated paths that still exist, in original order.
    public func load() -> [URL] {
        guard let data = try? Data(contentsOf: fileURL),
              let paths = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        var seen = Set<String>()
        return paths.compactMap { path in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard seen.insert(url.path).inserted else { return nil }
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
    }

    public func save(_ urls: [URL]) throws {
        var seen = Set<String>()
        let paths = urls.compactMap { url -> String? in
            let standardized = url.standardizedFileURL.path
            guard seen.insert(standardized).inserted else { return nil }
            return standardized
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(paths)
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
