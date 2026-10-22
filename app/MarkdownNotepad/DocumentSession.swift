import AppKit
import Foundation
import MarkdownCore
import SwiftUI
import UniformTypeIdentifiers

/// Owns one editable document window: its text, file location, on-disk format,
/// conflict state, find bar, and crash-recovery snapshots.
///
/// M2 replaces the M1 singleton with one session per window so tabs and
/// multiple windows each have independent dirty state, undo history, and find
/// state.
final class DocumentSession: ObservableObject, Identifiable {
    enum ConflictPrompt: Int, Identifiable {
        case externalChange
        var id: Int { rawValue }
    }

    let id = UUID()

    @Published private(set) var state: DocumentDirtyState
    @Published private(set) var format: TextFileFormat
    @Published private(set) var formatLabel: String
    @Published private(set) var recoveredFromCrash = false
    @Published var conflictPrompt: ConflictPrompt?
    @Published private(set) var wordWrap = true
    @Published private(set) var fontSize: CGFloat = 14
    @Published private(set) var isPreviewVisible = false
    let find = FindController()

    /// The preview starts open on wide windows, until the user explicitly
    /// toggles it with ⇧⌘P.
    private var previewManuallyToggled = false
    static let previewDefaultMinimumWidth = CGFloat(PreviewVisibility.defaultMinimumWidth)

    /// Called when the document gains/loses a file identity (open, Save As,
    /// Move to Trash) so the workspace can update recents and restoration.
    var onFileIdentityChanged: (() -> Void)?
    /// Called after any user-visible state change.
    var onChange: (() -> Void)?
    /// Called after the window has been allowed to close.
    var onClosed: (() -> Void)?

    private let workspace: WorkspaceCoordinator?
    private let io = MarkdownFileIO()
    private let recoveryStore = RecoveryStore(directory: RecoveryStore.defaultDirectory())
    private var baseline: FileFingerprint?
    private var untitledID = UUID()
    private var idleSnapshotTimer: Timer?
    private var periodicSnapshotTimer: Timer?
    private var isLoading = false
    private weak var window: NSWindow?
    private var closeGuard: WindowCloseGuard?

    init(
        workspace: WorkspaceCoordinator? = nil,
        openURL: URL? = nil,
        recoverSnapshot: Bool = false
    ) {
        self.workspace = workspace
        self.state = DocumentDirtyState()
        let initialFormat = TextFileFormat()
        self.format = initialFormat
        self.formatLabel = initialFormat.label
        find.onHighlightsChanged = { [weak self] in
            self?.textViewController?.highlighter.reapplyForeground()
        }

        if let openURL {
            load(url: openURL)
        } else if recoverSnapshot {
            restoreRecoverySnapshotIfNeeded()
        }
    }

    // MARK: - Presentation

    var text: String { state.text }
    var fileURL: URL? { state.fileURL }
    var isDirty: Bool { state.isDirty }
    var displayName: String { state.displayName }
    var windowTitle: String { isDirty ? "\(displayName) — Edited" : displayName }

    /// True when the window has never held a document and carries no edits, so
    /// a file opened from Finder can reuse it instead of leaving a blank
    /// window behind.
    var isPristineUntitled: Bool {
        fileURL == nil && text.isEmpty && !isDirty && !recoveredFromCrash
    }

    // MARK: - Editing

    func userEdited(_ newText: String) {
        guard !isLoading else { return }
        guard state.edit(newText) else { return }
        find.textDidChange()
        scheduleIdleSnapshot()
        startPeriodicSnapshots()
        notifyChanged()
    }

    // MARK: - Open

    func openDocument() {
        guard confirmDiscardIfNeeded() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.textContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url: url)
    }

    /// Opens a file in this window, replacing the current document after the
    /// unsaved-changes prompt.
    func load(url: URL) {
        do {
            let loaded = try io.load(from: url)
            applyLoaded(loaded)
            deleteRecoverySnapshot()
            stopSnapshots()
            onFileIdentityChanged?()
            notifyChanged()
        } catch {
            present(error)
        }
    }

    private func applyLoaded(_ loaded: LoadedTextFile) {
        isLoading = true
        state.load(text: loaded.textFile.text, fileURL: loaded.url)
        isLoading = false
        format = loaded.textFile.format
        formatLabel = format.label
        baseline = loaded.fingerprint
        recoveredFromCrash = false
        find.textDidChange()
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
            state.markSaved(at: destination)
            recoveredFromCrash = false
            stopSnapshots()
            try? recoveryStore.delete(documentID: previousIdentity)
            deleteRecoverySnapshot()
            onFileIdentityChanged?()
            notifyChanged()
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

    /// File > Revert to Saved.
    func revertToSaved() {
        guard let url = fileURL else { return }
        if isDirty {
            let alert = NSAlert()
            alert.messageText = "Revert to the last saved version of “\(displayName)”?"
            alert.informativeText = "Your current changes will be lost."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Revert")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        load(url: url)
    }

    func reloadFromDisk() {
        guard let url = fileURL else { return }
        load(url: url)
    }

    private func performSave(to url: URL, conflictPolicy: ConflictPolicy) {
        do {
            let textFile = TextFile(text: text, format: format)
            let fingerprint = try io.save(textFile, to: url, baseline: baseline, conflictPolicy: conflictPolicy)
            baseline = fingerprint
            state.markSaved()
            recoveredFromCrash = false
            stopSnapshots()
            deleteRecoverySnapshot()
            onFileIdentityChanged?()
            notifyChanged()
        } catch MarkdownCoreError.externalChange {
            if !FileManager.default.fileExists(atPath: url.path) {
                presentMissingFileSaveAs(url: url)
            } else {
                conflictPrompt = .externalChange
            }
        } catch {
            present(error)
        }
    }

    /// A vanished source file must never be silently recreated in place; we
    /// offer Save As instead.
    private func presentMissingFileSaveAs(url: URL) {
        let alert = NSAlert()
        alert.messageText = "“\(url.lastPathComponent)” no longer exists."
        alert.informativeText = "It may have been moved, renamed, or deleted. Save your text to a new location to keep it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save As…")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            saveAs()
        }
    }

    // MARK: - Trash

    func moveToTrash() {
        guard let url = fileURL else { return }

        if isDirty {
            let dirtyAlert = NSAlert()
            dirtyAlert.messageText = "“\(displayName)” has unsaved changes."
            dirtyAlert.informativeText = "Move the file on disk to the Trash anyway? Your unsaved text will be lost."
            dirtyAlert.alertStyle = .warning
            dirtyAlert.addButton(withTitle: "Move to Trash")
            dirtyAlert.addButton(withTitle: "Cancel")
            guard dirtyAlert.runModal() == .alertFirstButtonReturn else { return }
        }

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
            state.reset()
            isLoading = false
            baseline = nil
            format = TextFileFormat()
            formatLabel = format.label
            untitledID = UUID()
            recoveredFromCrash = false
            find.textDidChange()
            onFileIdentityChanged?()
            notifyChanged()
        } catch {
            present(error)
        }
    }

    // MARK: - Close / quit

    /// Closes this window (or tab) after the unsaved-changes prompt.
    func requestClose() {
        guard confirmClose() else { return }
        window?.close()
    }

    /// Prompts when needed; returns true when the window may close.
    func confirmClose() -> Bool {
        let canClose = confirmDiscardIfNeeded()
        if canClose {
            deleteRecoverySnapshot()
            stopSnapshots()
            find.detach()
            textViewController?.detach()
            textViewController = nil
            onClosed?()
        }
        return canClose
    }

    /// Returns true when the app may terminate for this session.
    func prepareForTermination() -> Bool {
        if isDirty {
            guard confirmDiscardIfNeeded() else { return false }
        }
        deleteRecoverySnapshot()
        stopSnapshots()
        return true
    }

    /// Save / Don't Save / Cancel. Cancel always preserves the work and the
    /// recovery snapshot.
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

    // MARK: - Go to line

    func goToLine() {
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.informativeText = "Enter a line number (1–\(lineCount))."
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Line number"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let requested = Int(field.stringValue.trimmingCharacters(in: .whitespaces)),
              requested >= 1 else { return }
        find.goToLine(requested)
    }

    var lineCount: Int {
        text.isEmpty ? 1 : text.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        }
    }

    // MARK: - Find

    func showFind(replace: Bool) {
        find.attachIfNeeded(to: textViewController?.textView)
        find.isVisible = true
        find.showReplace = replace
        find.textDidChange()
    }

    func hideFind() {
        find.isVisible = false
        find.clearHighlights()
    }

    func findNext() {
        showFind(replace: find.showReplace)
        find.next()
    }

    func findPrevious() {
        showFind(replace: find.showReplace)
        find.previous()
    }

    // MARK: - View

    func togglePreview() {
        previewManuallyToggled = true
        isPreviewVisible.toggle()
        notifyChanged()
    }

    /// Applies the width-based default until the user makes an explicit choice.
    func updatePreviewVisibility(for windowWidth: CGFloat) {
        guard !previewManuallyToggled, windowWidth > 0 else { return }
        let shouldShow = PreviewVisibility.shouldShowByDefault(windowWidth: Double(windowWidth))
        guard shouldShow != isPreviewVisible else { return }
        isPreviewVisible = shouldShow
        notifyChanged()
    }

    var previewBaseURL: URL? {
        fileURL
    }

    func toggleWordWrap() {
        wordWrap.toggle()
        notifyChanged()
    }

    func zoomIn() {
        fontSize = min(fontSize + 2, 42)
        notifyChanged()
    }

    func zoomOut() {
        fontSize = max(fontSize - 2, 9)
        notifyChanged()
    }

    func actualSize() {
        fontSize = 14
        notifyChanged()
    }

    // MARK: - Window integration

    private var textViewController: MarkdownTextController?

    func registerTextController(_ controller: MarkdownTextController) {
        textViewController = controller
        find.attachIfNeeded(to: controller.textView)
        find.textDidChange()
    }

    func attach(window: NSWindow) {
        self.window = window
        window.tabbingMode = .preferred
        window.isRestorable = false
        if closeGuard == nil {
            closeGuard = WindowCloseGuard(session: self)
        }
        if let closeGuard, window.delegate !== closeGuard {
            window.delegate = closeGuard
        }
        refreshWindowChrome()
        updatePreviewVisibility(for: window.frame.width)
    }

    func refreshWindowChrome() {
        window?.isDocumentEdited = isDirty
        window?.title = windowTitle
    }

    /// Brings this document's window to the front (used when the same file is
    /// opened again from Finder while it is already open).
    func focusWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidResize() {
        updatePreviewVisibility(for: window?.frame.width ?? 0)
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
        notifyChanged()
    }

    private func restoreRecoverySnapshotIfNeeded() {
        guard let snapshot = (try? recoveryStore.loadAll())?.first else { return }
        isLoading = true
        state.load(text: snapshot.text, fileURL: snapshot.fileURL.map { URL(fileURLWithPath: $0) })
        state.markRecovered()
        isLoading = false
        format = snapshot.format
        formatLabel = format.label
        baseline = snapshot.baseline
        recoveredFromCrash = true
        startPeriodicSnapshots()
    }

    // MARK: - Helpers

    private func notifyChanged() {
        refreshWindowChrome()
        onChange?()
    }

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

/// Retained by the session; `NSWindow.delegate` is weak.
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    private weak var session: DocumentSession?

    init(session: DocumentSession) {
        self.session = session
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        session?.confirmClose() ?? true
    }

    func windowDidBecomeKey(_ notification: Notification) {
        session?.refreshWindowChrome()
    }

    func windowDidResize(_ notification: Notification) {
        session?.windowDidResize()
    }
}
