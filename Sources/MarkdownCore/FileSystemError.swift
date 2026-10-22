import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Translates Foundation/POSIX errors into user-facing `MarkdownCoreError` cases.
enum FileSystemError {
    static func map(_ error: Error, url: URL? = nil) -> MarkdownCoreError {
        if let coreError = error as? MarkdownCoreError { return coreError }
        let nsError = error as NSError

        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case 4, 260:
                return .fileNotFound
            case 257, 513, 516:
                return .permissionDenied
            case 640, 642:
                return .diskFull
            default:
                break
            }
        }

        if nsError.domain == "NSPOSIXErrorDomain" {
            switch Int32(nsError.code) {
            case EACCES, EPERM:
                return .permissionDenied
            case ENOENT:
                return .fileNotFound
            case ENOTDIR:
                return .directoryNotFound
            case ENOSPC, EDQUOT:
                return .diskFull
            case EINTR:
                return .interruptedWrite
            default:
                break
            }
        }

        return .ioFailure(nsError.localizedDescription)
    }

    static func errnoToCoreError(_ code: Int32) -> MarkdownCoreError {
        switch code {
        case EACCES, EPERM:
            return .permissionDenied
        case ENOENT:
            return .fileNotFound
        case ENOTDIR:
            return .directoryNotFound
        case ENOSPC, EDQUOT:
            return .diskFull
        case EINTR:
            return .interruptedWrite
        default:
            return .ioFailure(String(cString: strerror(code)))
        }
    }
}
