import Foundation

/// A text file read from disk together with the identity used for conflict checks.
public struct LoadedTextFile: Sendable {
    public let url: URL
    public let textFile: TextFile
    public let fingerprint: FileFingerprint

    public init(url: URL, textFile: TextFile, fingerprint: FileFingerprint) {
        self.url = url
        self.textFile = textFile
        self.fingerprint = fingerprint
    }
}

/// Read, atomic-write, save-as, and Trash operations for markdown text files.
///
/// All writes go through `AtomicFileWriter`, so a failure at any point leaves
/// the original file exactly as it was. Reads and writes are wrapped in
/// `NSFileCoordinator` on macOS; the Linux build uses the same code paths
/// without the coordinator so the core can be unit-tested on CI.
public struct MarkdownFileIO: Sendable {
    public init() {}

    // MARK: - Reading

    /// Reads and decodes a UTF-8 text file.
    ///
    /// - Throws: `MarkdownCoreError.notUTF8` for non-UTF-8 bytes,
    ///   `.fileNotFound` when the path is missing, and mapped I/O errors otherwise.
    public func load(from url: URL) throws -> LoadedTextFile {
        try coordinatedRead(url) {
            let fileManager = FileManager.default
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw MarkdownCoreError.fileNotFound
            }
            if isDirectory.boolValue {
                throw MarkdownCoreError.ioFailure("The path is a folder, not a file.")
            }

            let data: Data
            do {
                data = try Data(contentsOf: url, options: [.mappedIfSafe])
            } catch {
                throw FileSystemError.map(error, url: url)
            }

            let textFile = try TextFile.decode(data)
            let modification = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            let fingerprint = FileFingerprint(
                byteCount: data.count,
                modificationTime: modification?.timeIntervalSince1970,
                sha256: SHA256.hexDigest(of: data)
            )
            return LoadedTextFile(url: url, textFile: textFile, fingerprint: fingerprint)
        }
    }

    /// Captures the current fingerprint, or `nil` when the file no longer exists.
    public func fingerprint(of url: URL) throws -> FileFingerprint? {
        try FileFingerprint.capture(at: url)
    }

    // MARK: - Writing

    /// Atomically writes a text file.
    ///
    /// - Parameters:
    ///   - textFile: Text plus the BOM/line-ending format to re-apply.
    ///   - url: Destination path.
    ///   - baseline: Fingerprint captured when the file was opened. When the
    ///     current contents differ, the save is refused unless the policy is
    ///     `.overwrite`.
    ///   - conflictPolicy: `.fail` (default) never silently overwrites.
    /// - Returns: The new fingerprint after a successful write.
    @discardableResult
    public func save(
        _ textFile: TextFile,
        to url: URL,
        baseline: FileFingerprint?,
        conflictPolicy: ConflictPolicy = .fail
    ) throws -> FileFingerprint {
        try save(textFile, to: url, baseline: baseline, conflictPolicy: conflictPolicy, fault: nil)
    }

    /// Test seam: identical to `save`, with an injectable write fault.
    @discardableResult
    func save(
        _ textFile: TextFile,
        to url: URL,
        baseline: FileFingerprint?,
        conflictPolicy: ConflictPolicy,
        fault: WriteFault?
    ) throws -> FileFingerprint {
        if let baseline {
            let current = try FileFingerprint.capture(at: url)
            guard let current else {
                throw MarkdownCoreError.externalChange
            }
            if !current.hasSameContent(as: baseline), conflictPolicy == .fail {
                throw MarkdownCoreError.externalChange
            }
        }

        let data = textFile.encodedBytes()
        try coordinatedWrite(url) {
            try AtomicFileWriter.write(data, to: url, fault: fault)
        }
        return try FileFingerprint.capture(at: url)
            ?? FileFingerprint(byteCount: data.count, modificationTime: nil, sha256: SHA256.hexDigest(of: data))
    }

    /// Writes to a new destination without touching the source file.
    @discardableResult
    public func saveAs(_ textFile: TextFile, to url: URL) throws -> FileFingerprint {
        try saveAs(textFile, to: url, fault: nil)
    }

    /// Test seam: identical to `saveAs`, with an injectable write fault.
    @discardableResult
    func saveAs(_ textFile: TextFile, to url: URL, fault: WriteFault?) throws -> FileFingerprint {
        let data = textFile.encodedBytes()
        try coordinatedWrite(url) {
            try AtomicFileWriter.write(data, to: url, fault: fault)
        }
        return try FileFingerprint.capture(at: url)
            ?? FileFingerprint(byteCount: data.count, modificationTime: nil, sha256: SHA256.hexDigest(of: data))
    }

    // MARK: - Trash

    /// Moves a file to the system Trash and returns the resulting URL when known.
    @discardableResult
    public func moveToTrash(_ url: URL) throws -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            throw MarkdownCoreError.fileNotFound
        }

        #if canImport(Darwin)
        var resultingURL: NSURL?
        do {
            try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
        } catch {
            throw MarkdownCoreError.trashFailed(error.localizedDescription)
        }
        return resultingURL as URL?
        #else
        return try moveToFreedesktopTrash(url)
        #endif
    }

    #if !canImport(Darwin)
    private func moveToFreedesktopTrash(_ url: URL) throws -> URL {
        let fileManager = FileManager.default
        let dataHome: URL
        if let override = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !override.isEmpty {
            dataHome = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            dataHome = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share", isDirectory: true)
        }

        let trashRoot = dataHome.appendingPathComponent("Trash", isDirectory: true)
        let filesDirectory = trashRoot.appendingPathComponent("files", isDirectory: true)
        let infoDirectory = trashRoot.appendingPathComponent("info", isDirectory: true)

        do {
            try fileManager.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: infoDirectory, withIntermediateDirectories: true)
        } catch {
            throw MarkdownCoreError.trashFailed(error.localizedDescription)
        }

        let originalName = url.lastPathComponent
        let base = (originalName as NSString).deletingPathExtension
        let pathExtension = (originalName as NSString).pathExtension
        var candidate = originalName
        var suffix = 1
        while fileManager.fileExists(atPath: filesDirectory.appendingPathComponent(candidate).path) {
            suffix += 1
            candidate = pathExtension.isEmpty ? "\(base).\(suffix)" : "\(base).\(suffix).\(pathExtension)"
        }

        let destination = filesDirectory.appendingPathComponent(candidate)
        let infoURL = infoDirectory.appendingPathComponent(candidate + ".trashinfo")
        let encodedPath = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        let info = "[Trash Info]\nPath=\(encodedPath)\nDeletionDate=\(ISO8601DateFormatter().string(from: Date()))\n"

        do {
            try info.write(to: infoURL, atomically: true, encoding: .utf8)
            try fileManager.moveItem(at: url, to: destination)
        } catch {
            try? fileManager.removeItem(at: infoURL)
            throw MarkdownCoreError.trashFailed(error.localizedDescription)
        }
        return destination
    }
    #endif

    // MARK: - Coordination

    private func coordinatedRead<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        #if canImport(Darwin)
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var output: Result<T, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { _ in
            output = Result { try body() }
        }
        if let coordinationError {
            throw FileSystemError.map(coordinationError, url: url)
        }
        guard let output else {
            throw MarkdownCoreError.ioFailure("File coordination did not run.")
        }
        return try output.get()
        #else
        return try body()
        #endif
    }

    private func coordinatedWrite<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        #if canImport(Darwin)
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var output: Result<T, Error>?
        coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError) { _ in
            output = Result { try body() }
        }
        if let coordinationError {
            throw FileSystemError.map(coordinationError, url: url)
        }
        guard let output else {
            throw MarkdownCoreError.ioFailure("File coordination did not run.")
        }
        return try output.get()
        #else
        return try body()
        #endif
    }
}
