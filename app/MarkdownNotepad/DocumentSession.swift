import AppKit
import Foundation
import MarkdownCore
import SwiftUI
import UniformTypeIdentifiers

/// Owns one editable document: its text, file location, on-disk format,
/// conflict state, and crash-recovery snapshots.
///
/// The single-window M1 build uses `shared`; the M2 milestone replaces this with
/// per-window sessions.
final class DocumentSession: ObservableObject {
    static let shared = DocumentSession()

    enum ConflictPrompt: Int, Identifiable {
        case externalChange
        var id: Int { rawValue }
    }

    @Published private(set) var text: String = ""
    @Published private(set) var fileURL: URL?
    @Published private(set) var isDirty = false
    @Published private(set) var formatLabel = TextFileFormat().label
    @Published var conflictPrompt: ConflictPrompt?
    @Published private(set) var recoveredFromCrash = false

    private let io = MarkdownFileIO()
    private let recoveryStore = RecoveryStore(directory: RecoveryStore.defaultDirectory())
    private var format = TextFileFormat()
    private var baseline: FileFingerprint?
    private var untitledID = UUID()
    private var idleSnapshotTimer: Timer?
    private var periodicSnapshotTimer: Timer?
    private var isLoading = false

    private init() {
        self.formatLabel = format.label
        restoreRecoverySnapshotIfNeeded()
    }

    // MARK: - Presentation

    var displayName: String {
        fileURL?.lastPathComponent ?? "Untitled"
    }

    var windowTitle: String {
        let name = displayName
        return isDirty ? "\(name) — Edited" : name
    }

    // MARK: - Editing

    func userEdited(_ newText: String) {
        guard !isLoading, newText != text else { return }
        text = newText
        isDirty = true
        scheduleIdleSnapshot()
        startPeriodicSnapshots()
    }

    // MARK: - New / Open

    func newDocument() {
        guard confirmDiscardIfNeeded() else { return }
        deleteRecoverySnapshot()
        isLoading = true
        text = ""
        isLoading = false
        fileURL = nil
        baseline = nil
        format = TextFileFormat()
        formatLabel = format.label
        untitledID = UUID()
        isDirty = false
        recoveredFromCrash = false
        stopSnapshots()
    }

    func openDocument() {
        guard confirmDiscardIfNeeded() else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.textContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    func open(url: URL) {
        do {
            let loaded = try io.load(from: url)
            deleteRecoverySnapshot()
            isLoading = true
            text = loaded.textFile.text
            isLoading = false
            format = loaded.textFile.format
            formatLabel = format.label
            baseline = loaded.fingerprint
            fileURL = url
            isDirty = false
            recoveredFromCrash = false
            stopSnapshots()
        } catch {
            present(error)
        }
    }

    // MARK: - Save

    func save() {
        guard let url = fileURL else {
            saveAs()
            return
        }
        performSave(to: url, conflictPolicy: .fail)
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = Self.textContentTypes
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "Untitled.md"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            let textFile = TextFile(text: text, format: format)
            let fingerprint = try io.saveAs(textFile, to: destination)
            let previousIdentity = recoveryIdentity
            baseline = fingerprint
            fileURL = destination
            isDirty = false
            recoveredFromCrash = false
            stopSnapshots()
            try? recoveryStore.delete(documentID: previousIdentity)
            deleteRecoverySnapshot()
        } catch {
            present(error)
        }
    }

    func overwriteWithCurrentText() {
        guard let url = fileURL else {
            saveAs()
            return
        }
        performSave(to: url, conflictPolicy: .overwrite)
    }

    func reloadFromDisk() {
        guard let url = fileURL else { return }
        open(url: url)
    }

    private func performSave(to url: URL, conflictPolicy: ConflictPolicy) {
        do {
            let textFile = TextFile(text: text, format: format)
            let fingerprint = try io.save(textFile, to: url, baseline: baseline, conflictPolicy: conflictPolicy)
            baseline = fingerprint
            isDirty = false
            recoveredFromCrash = false
            stopSnapshots()
            deleteRecoverySnapshot()
        } catch MarkdownCoreError.externalChange {
            conflictPrompt = .externalChange
        } catch {
            present(error)
        }
    }

    // MARK: - Trash

    func moveToTrash() {
        guard let url = fileURL else { return }

        let alert = NSAlert()
        alert.messageText = "Move “\(url.lastPathComponent)” to the Trash?"
        alert.informativeText = "The file can be recovered from the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try io.moveToTrash(url)
            deleteRecoverySnapshot()
            stopSnapshots()
            isLoading = true
            text = ""
            isLoading = false
            fileURL = nil
            baseline = nil
            format = TextFileFormat()
            formatLabel = format.label
            untitledID = UUID()
            isDirty = false
            recoveredFromCrash = false
        } catch {
            present(error)
        }
    }

    // MARK: - Quit

    /// Returns true when the app may terminate.
    func prepareForTermination() -> Bool {
        if isDirty {
            guard confirmDiscardIfNeeded() else { return false }
        }
        deleteRecoverySnapshot()
        stopSnapshots()
        return true
    }

    private func confirmDiscardIfNeeded() -> Bool {
        guard isDirty else { return true }

        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes to “\(displayName)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            save()
            return !isDirty
        case .alertSecondButtonReturn:
            deleteRecoverySnapshot()
            stopSnapshots()
            return true
        default:
            return false
        }
    }

    // MARK: - Recovery

    private var recoveryIdentity: String {
        if let fileURL {
            return RecoveryStore.documentID(for: fileURL)
        }
        return RecoveryStore.documentID(forUntitled: untitledID)
    }

    private func snapshotIfDirty() {
        guard isDirty else { return }
        let snapshot = RecoverySnapshot(
            documentID: recoveryIdentity,
            fileURL: fileURL?.path,
            text: text,
            format: format,
            baseline: baseline
        )
        try? recoveryStore.save(snapshot)
    }

    private func scheduleIdleSnapshot() {
        idleSnapshotTimer?.invalidate()
        idleSnapshotTimer = Timer.scheduledTimer(
            timeInterval: 2,
            target: self,
            selector: #selector(idleSnapshotFired),
            userInfo: nil,
            repeats: false
        )
    }

    private func startPeriodicSnapshots() {
        guard periodicSnapshotTimer == nil else { return }
        periodicSnapshotTimer = Timer.scheduledTimer(
            timeInterval: 30,
            target: self,
            selector: #selector(periodicSnapshotFired),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func idleSnapshotFired() {
        idleSnapshotTimer = nil
        snapshotIfDirty()
    }

    @objc private func periodicSnapshotFired() {
        snapshotIfDirty()
    }

    private func stopSnapshots() {
        idleSnapshotTimer?.invalidate()
        idleSnapshotTimer = nil
        periodicSnapshotTimer?.invalidate()
        periodicSnapshotTimer = nil
    }

    private func deleteRecoverySnapshot() {
        try? recoveryStore.delete(documentID: recoveryIdentity)
    }

    func acknowledgeRecovery() {
        recoveredFromCrash = false
    }

    private func restoreRecoverySnapshotIfNeeded() {
        guard let snapshot = (try? recoveryStore.loadAll())?.first else { return }
        isLoading = true
        text = snapshot.text
        isLoading = false
        format = snapshot.format
        formatLabel = format.label
        baseline = snapshot.baseline
        fileURL = snapshot.fileURL.map { URL(fileURLWithPath: $0) }
        isDirty = true
        recoveredFromCrash = true
        startPeriodicSnapshots()
    }

    // MARK: - Helpers

    private static var textContentTypes: [UTType] {
        var types: [UTType] = []
        if let markdown = UTType(filenameExtension: "md") {
            types.append(markdown)
        }
        types.append(.plainText)
        return types
    }

    private func present(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t complete that file operation"
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
