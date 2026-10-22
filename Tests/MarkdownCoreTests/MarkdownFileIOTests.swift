import Foundation
import XCTest
@testable import MarkdownCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class MarkdownFileIOTests: XCTestCase {
    private var tempDirectory: URL!
    private let io = MarkdownFileIO()

    override func setUpWithError() throws {
        tempDirectory = try makeTempDirectory()
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            removeTempDirectory(tempDirectory)
        }
    }

    private func write(_ bytes: Data, named name: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func visibleFileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path).sorted()
    }

    // MARK: - Round trip through the public API

    func testLoadAndSaveRoundTripsGoldenFilesThroughPublicAPI() throws {
        for name in ["lf", "crlf", "mixed", "bom_lf", "bom_crlf", "unicode", "empty", "bom_only"] {
            let target = try write(Fixtures.data(name), named: "\(name).md")
            let loaded = try io.load(from: target)
            try io.save(loaded.textFile, to: target, baseline: loaded.fingerprint)
            XCTAssertEqual(
                try Data(contentsOf: target),
                Fixtures.data(name),
                "\(name).md changed during load+save"
            )
        }
    }

    func testSavePreservesPermissions() throws {
        let target = try write(Fixtures.data("lf"), named: "perms.md")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)

        let loaded = try io.load(from: target)
        try io.save(loaded.textFile, to: target, baseline: loaded.fingerprint)

        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o600)
    }

    func testSaveUpdatesFingerprint() throws {
        let target = try write(Data("one\n".utf8), named: "fingerprint.md")
        let loaded = try io.load(from: target)
        var textFile = loaded.textFile
        textFile.text = "two\n"
        let newFingerprint = try io.save(textFile, to: target, baseline: loaded.fingerprint)
        XCTAssertNotEqual(newFingerprint.sha256, loaded.fingerprint.sha256)
        XCTAssertEqual(try Data(contentsOf: target), Data("two\n".utf8))
    }

    func testSaveToNewFileWithNilBaseline() throws {
        let target = tempDirectory.appendingPathComponent("brand-new.md")
        let fingerprint = try io.save(TextFile(text: "hi\n"), to: target, baseline: nil)
        XCTAssertEqual(try Data(contentsOf: target), Data("hi\n".utf8))
        XCTAssertEqual(fingerprint.byteCount, 3)
    }

    // MARK: - Fault injection

    func testEveryFailedSaveLeavesOriginalBytesIntact() throws {
        let original = Fixtures.data("crlf")
        let faults: [WriteFault] = [
            .diskFullDuringWrite,
            .interruptedAfterTempWrite,
            .permissionDeniedBeforeReplace,
            .cannotCreateTempFile
        ]

        for fault in faults {
            let target = try write(original, named: "fault-\(fault).md")
            let loaded = try io.load(from: target)

            XCTAssertThrowsError(
                try io.save(
                    TextFile(text: "replacement\n", format: loaded.textFile.format),
                    to: target,
                    baseline: loaded.fingerprint,
                    conflictPolicy: .fail,
                    fault: fault
                ),
                "fault \(fault) should throw"
            )

            XCTAssertEqual(try Data(contentsOf: target), original, "fault \(fault) damaged the original")
            let leftovers = try visibleFileNames().filter { $0.hasPrefix(".fault-") }
            XCTAssertTrue(leftovers.isEmpty, "fault \(fault) left temp files: \(leftovers)")
        }
    }

    func testDiskFullErrorIsSpecific() throws {
        let target = try write(Data("original\n".utf8), named: "disk-full.md")
        let loaded = try io.load(from: target)
        XCTAssertThrowsError(
            try io.save(
                TextFile(text: "new\n", format: loaded.textFile.format),
                to: target,
                baseline: loaded.fingerprint,
                conflictPolicy: .fail,
                fault: .diskFullDuringWrite
            )
        ) { error in
            XCTAssertEqual(error as? MarkdownCoreError, .diskFull)
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("original\n".utf8))
    }

    func testInterruptedWriteErrorIsSpecific() throws {
        let target = try write(Data("original\n".utf8), named: "interrupted.md")
        let loaded = try io.load(from: target)
        XCTAssertThrowsError(
            try io.save(
                TextFile(text: "new\n", format: loaded.textFile.format),
                to: target,
                baseline: loaded.fingerprint,
                conflictPolicy: .fail,
                fault: .interruptedAfterTempWrite
            )
        ) { error in
            XCTAssertEqual(error as? MarkdownCoreError, .interruptedWrite)
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("original\n".utf8))
    }

    func testReadOnlyDirectorySaveFailsAndKeepsOriginal() throws {
        #if canImport(Glibc) || canImport(Darwin)
        if geteuid() == 0 {
            throw XCTSkip("Permission checks are bypassed when running as root (CI container).")
        }
        #endif

        let target = try write(Data("original\n".utf8), named: "readonly.md")
        let loaded = try io.load(from: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: tempDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tempDirectory.path)
        }

        var replacement = loaded.textFile
        replacement.text = "new\n"
        XCTAssertThrowsError(try io.save(replacement, to: target, baseline: loaded.fingerprint)) { error in
            XCTAssertEqual(error as? MarkdownCoreError, .permissionDenied)
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("original\n".utf8))
    }

    // MARK: - Conflict detection

    func testExternalChangeIsDetectedAndNotOverwritten() throws {
        let target = try write(Data("version one\n".utf8), named: "conflict.md")
        let loaded = try io.load(from: target)

        try Data("externally edited\n".utf8).write(to: target)

        var edited = loaded.textFile
        edited.text = "my edit\n"
        XCTAssertThrowsError(try io.save(edited, to: target, baseline: loaded.fingerprint)) { error in
            XCTAssertEqual(error as? MarkdownCoreError, .externalChange)
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("externally edited\n".utf8))
    }

    func testOverwritePolicyReplacesAfterExternalChange() throws {
        let target = try write(Data("version one\n".utf8), named: "overwrite.md")
        let loaded = try io.load(from: target)
        try Data("externally edited\n".utf8).write(to: target)

        var edited = loaded.textFile
        edited.text = "deliberate overwrite\n"
        let newFingerprint = try io.save(
            edited,
            to: target,
            baseline: loaded.fingerprint,
            conflictPolicy: .overwrite
        )

        XCTAssertEqual(try Data(contentsOf: target), Data("deliberate overwrite\n".utf8))
        let current = try XCTUnwrap(io.fingerprint(of: target))
        XCTAssertTrue(newFingerprint.hasSameContent(as: current))
    }

    func testDeletedFileCountsAsConflict() throws {
        let target = try write(Data("version one\n".utf8), named: "deleted.md")
        let loaded = try io.load(from: target)
        try FileManager.default.removeItem(at: target)

        XCTAssertThrowsError(try io.save(loaded.textFile, to: target, baseline: loaded.fingerprint)) { error in
            XCTAssertEqual(error as? MarkdownCoreError, .externalChange)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testTouchingWithoutContentChangeIsNotAConflict() throws {
        let target = try write(Data("same\n".utf8), named: "touch.md")
        let loaded = try io.load(from: target)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(30)],
            ofItemAtPath: target.path
        )

        XCTAssertNoThrow(try io.save(loaded.textFile, to: target, baseline: loaded.fingerprint))
        XCTAssertEqual(try Data(contentsOf: target), Data("same\n".utf8))
    }

    // MARK: - Save As

    func testSaveAsDoesNotTouchSource() throws {
        let source = try write(Data("source\n".utf8), named: "source.md")
        let loaded = try io.load(from: source)
        let destination = tempDirectory.appendingPathComponent("copy.md")

        var edited = loaded.textFile
        edited.text = "copy contents\n"
        try io.saveAs(edited, to: destination)

        XCTAssertEqual(try Data(contentsOf: source), Data("source\n".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("copy contents\n".utf8))
    }

    func testSaveAsOverwritesDestinationAtomically() throws {
        let destination = try write(Data("old destination\n".utf8), named: "existing.md")
        try io.saveAs(TextFile(text: "new destination\n"), to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("new destination\n".utf8))
    }

    // MARK: - Rename / move

    func testMoveRenamesFileWithoutChangingBytes() throws {
        let source = try write(Fixtures.data("mixed"), named: "before.md")
        let destination = tempDirectory.appendingPathComponent("after.md")

        let moved = try io.move(source, to: destination)

        XCTAssertEqual(moved.standardizedFileURL.path, destination.standardizedFileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: destination), Fixtures.data("mixed"))
    }

    func testMoveRefusesExistingDestinationAndLeavesBothFilesIntact() throws {
        let source = try write(Data("source\n".utf8), named: "source.md")
        let destination = try write(Data("existing\n".utf8), named: "existing.md")

        XCTAssertThrowsError(try io.move(source, to: destination)) { error in
            XCTAssertEqual(error as? MarkdownCoreError, .destinationExists)
        }
        XCTAssertEqual(try Data(contentsOf: source), Data("source\n".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("existing\n".utf8))
    }

    func testMoveToSamePathIsANoOp() throws {
        let source = try write(Data("same\n".utf8), named: "same.md")
        XCTAssertNoThrow(try io.move(source, to: source))
        XCTAssertEqual(try Data(contentsOf: source), Data("same\n".utf8))
    }

    func testMoveMissingSourceThrows() {
        let source = tempDirectory.appendingPathComponent("missing.md")
        let destination = tempDirectory.appendingPathComponent("destination.md")
        XCTAssertThrowsError(try io.move(source, to: destination)) { error in
            XCTAssertEqual(error as? MarkdownCoreError, .fileNotFound)
        }
    }

    func testMoveToMissingDirectoryThrows() throws {
        let source = try write(Data("source\n".utf8), named: "source.md")
        let destination = tempDirectory
            .appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("destination.md")
        XCTAssertThrowsError(try io.move(source, to: destination)) { error in
            XCTAssertEqual(error as? MarkdownCoreError, .directoryNotFound)
        }
        XCTAssertEqual(try Data(contentsOf: source), Data("source\n".utf8))
    }

    func testSaveNewRefusesExistingDestination() throws {
        let destination = try write(Data("existing\n".utf8), named: "existing.md")
        XCTAssertThrowsError(try io.saveNew(TextFile(text: "replacement\n"), to: destination)) { error in
            XCTAssertEqual(error as? MarkdownCoreError, .destinationExists)
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("existing\n".utf8))
    }

    func testSaveNewWritesBrandNewFile() throws {
        let destination = tempDirectory.appendingPathComponent("brand-new.md")
        try io.saveNew(TextFile(text: "new\n"), to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("new\n".utf8))
    }

    // MARK: - Trash

    func testMoveToTrashRemovesOriginalAndLeavesTrashedCopy() throws {
        // Point the Linux freedesktop Trash at the temp dir so the test never
        // touches the real user Trash.
        let trashHome = tempDirectory.appendingPathComponent("trash-home", isDirectory: true)
        try FileManager.default.createDirectory(at: trashHome, withIntermediateDirectories: true)
        let previous = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
        setenv("XDG_DATA_HOME", trashHome.path, 1)
        defer {
            if let previous {
                setenv("XDG_DATA_HOME", previous, 1)
            } else {
                unsetenv("XDG_DATA_HOME")
            }
        }

        let target = try write(Data("to trash\n".utf8), named: "trash-me.md")
        let trashed = try io.moveToTrash(target)

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        if let trashedURL = trashed {
            XCTAssertTrue(FileManager.default.fileExists(atPath: trashedURL.path))
            XCTAssertEqual(try Data(contentsOf: trashedURL), Data("to trash\n".utf8))
        }
    }

    func testMoveMissingFileToTrashThrows() {
        let missing = tempDirectory.appendingPathComponent("missing.md")
        XCTAssertThrowsError(try io.moveToTrash(missing)) { error in
            XCTAssertEqual(error as? MarkdownCoreError, .fileNotFound)
        }
    }

    // MARK: - Reads

    func testLoadMissingFileThrowsFileNotFound() {
        let missing = tempDirectory.appendingPathComponent("missing.md")
        XCTAssertThrowsError(try io.load(from: missing)) { error in
            XCTAssertEqual(error as? MarkdownCoreError, .fileNotFound)
        }
    }

    func testLoadDirectoryThrows() {
        XCTAssertThrowsError(try io.load(from: tempDirectory))
    }

    func testLoadNonUTF8DoesNotModifyFile() throws {
        let original = Data([0x4C, 0x61, 0xFF, 0x74, 0x69, 0x6E])
        let target = try write(original, named: "latin1.md")
        XCTAssertThrowsError(try io.load(from: target)) { error in
            XCTAssertEqual(error as? MarkdownCoreError, .notUTF8)
        }
        XCTAssertEqual(try Data(contentsOf: target), original)
    }
}
