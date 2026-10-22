import Foundation

/// Errors surfaced by `MarkdownCore` file operations.
///
/// Every case is non-destructive: a failed read or write never modifies the
/// user's source file. Messages are written for end users, not developers.
public enum MarkdownCoreError: Error, Equatable, Sendable, LocalizedError {
    /// The bytes are not valid UTF-8. The file was not modified.
    case notUTF8
    /// The file changed on disk after it was opened.
    case externalChange
    /// The requested path does not exist.
    case fileNotFound
    /// The destination directory does not exist.
    case directoryNotFound
    /// A file already exists at the destination; it was not overwritten.
    case destinationExists
    /// The process is not allowed to read or write the path.
    case permissionDenied
    /// The volume ran out of space. The original file is intact.
    case diskFull
    /// A write was interrupted before the atomic replace. The original is intact.
    case interruptedWrite
    /// Any other I/O failure, with a human-readable detail string.
    case ioFailure(String)
    /// Moving the file to the Trash failed.
    case trashFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notUTF8:
            return "This file is not UTF-8 text. It was not opened or changed."
        case .externalChange:
            return "This file changed on disk since you opened it. Choose Reload, Overwrite, or Save As."
        case .fileNotFound:
            return "The file could not be found."
        case .directoryNotFound:
            return "The folder could not be found."
        case .destinationExists:
            return "A file with that name already exists. Choose a different name or folder. The existing file was not changed."
        case .permissionDenied:
            return "You do not have permission to read or write this file. The original file was not changed."
        case .diskFull:
            return "The disk is full. The original file was not changed."
        case .interruptedWrite:
            return "The save was interrupted. The original file was not changed."
        case .ioFailure(let detail):
            return "The file could not be read or written: \(detail)"
        case .trashFailed(let detail):
            return "The file could not be moved to the Trash: \(detail)"
        }
    }
}

/// How a save should behave when the file changed on disk since it was opened.
public enum ConflictPolicy: Sendable {
    /// Refuse to write and throw `MarkdownCoreError.externalChange`.
    case fail
    /// Replace the file even though it changed on disk (explicit user choice).
    case overwrite
}
