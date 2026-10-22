import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Fault injection hook used by tests to prove a failed save never damages the
/// original file. Production callers never pass a fault.
enum WriteFault: Sendable {
    /// Simulate the volume filling up partway through writing the temp file.
    case diskFullDuringWrite
    /// Simulate losing permission just before the atomic replace.
    case permissionDeniedBeforeReplace
    /// Simulate the process dying after the temp file is written but before replace.
    case interruptedAfterTempWrite
    /// Simulate the temp file itself being unwritable at creation time.
    case cannotCreateTempFile
}

/// Writes bytes atomically: temp file in the destination directory, fsync,
/// preserve permissions, then replace the original in one step.
///
/// If any stage fails the original file is untouched and the temp file is
/// removed. Re-running the same write is safe and produces the same bytes.
enum AtomicFileWriter {
    static func write(_ data: Data, to destination: URL, fault: WriteFault? = nil) throws {
        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MarkdownCoreError.directoryNotFound
        }

        var destinationIsDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destination.path, isDirectory: &destinationIsDirectory),
           destinationIsDirectory.boolValue {
            throw MarkdownCoreError.ioFailure("The destination is a folder.")
        }

        let existingPermissions = (try? fileManager.attributesOfItem(atPath: destination.path))?[.posixPermissions] as? NSNumber
        let permissions = mode_t(existingPermissions?.intValue ?? 0o644)

        if fault == .cannotCreateTempFile {
            throw MarkdownCoreError.permissionDenied
        }

        let tempURL = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )

        let descriptor = open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard descriptor >= 0 else {
            throw FileSystemError.errnoToCoreError(errno)
        }

        var shouldRemoveTemp = true
        defer {
            if shouldRemoveTemp {
                unlink(tempURL.path)
            }
        }

        try writeAll(data, to: descriptor, fault: fault, tempURL: tempURL)
        shouldRemoveTemp = false

        if fsync(descriptor) != 0 {
            let code = errno
            close(descriptor)
            unlink(tempURL.path)
            throw FileSystemError.errnoToCoreError(code)
        }
        if close(descriptor) != 0 {
            let code = errno
            unlink(tempURL.path)
            throw FileSystemError.errnoToCoreError(code)
        }

        if chmod(tempURL.path, permissions) != 0 {
            let code = errno
            unlink(tempURL.path)
            throw FileSystemError.errnoToCoreError(code)
        }

        if fault == .interruptedAfterTempWrite {
            unlink(tempURL.path)
            throw MarkdownCoreError.interruptedWrite
        }
        if fault == .permissionDeniedBeforeReplace {
            unlink(tempURL.path)
            throw MarkdownCoreError.permissionDenied
        }

        try replace(destination: destination, with: tempURL, fileManager: fileManager)
        fsyncDirectory(directory)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32, fault: WriteFault?, tempURL: URL) throws {
        let bytes = [UInt8](data)
        var offset = 0

        while offset < bytes.count {
            let requested = fault == .diskFullDuringWrite
                ? min(bytes.count - offset, 16)
                : bytes.count - offset

            let written = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return posixWrite(descriptor, base.advanced(by: offset), requested)
            }

            if written < 0 {
                let code = errno
                if code == EINTR { continue }
                close(descriptor)
                unlink(tempURL.path)
                throw FileSystemError.errnoToCoreError(code)
            }
            if written == 0 { break }
            offset += written
        }

        if fault == .diskFullDuringWrite {
            close(descriptor)
            unlink(tempURL.path)
            throw MarkdownCoreError.diskFull
        }
    }

    private static func posixWrite(_ descriptor: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.write(descriptor, buffer, count)
        #else
        return Glibc.write(descriptor, buffer, count)
        #endif
    }

    private static func replace(destination: URL, with tempURL: URL, fileManager: FileManager) throws {
        #if canImport(Darwin)
        if fileManager.fileExists(atPath: destination.path) {
            do {
                _ = try fileManager.replaceItemAt(destination, withItemAt: tempURL)
            } catch {
                unlink(tempURL.path)
                throw FileSystemError.map(error, url: destination)
            }
        } else {
            if rename(tempURL.path, destination.path) != 0 {
                let code = errno
                unlink(tempURL.path)
                throw FileSystemError.errnoToCoreError(code)
            }
        }
        #else
        if rename(tempURL.path, destination.path) != 0 {
            let code = errno
            unlink(tempURL.path)
            throw FileSystemError.errnoToCoreError(code)
        }
        #endif
    }

    private static func fsyncDirectory(_ directory: URL) {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        close(descriptor)
    }
}
