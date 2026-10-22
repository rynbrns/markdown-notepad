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
    let id = UUID()

    @Published private(set) var state: DocumentDirtyState
    @Published private(set) var format: TextFileFormat
    @Published private(set) var formatLabel: String
    @Published private(set) var recoveredFromCrash = false
    /// The filename an untitled document should use on its first save, set by
    /// the inline title-bar rename before a file exists on disk.
    @Published private(set) var untitledName: String?
    @Published private(set) var wordWrap = true
    @Published private(set) var fontSize: CGFloat = 14
    /// The active presentation mode. The underlying `state.text` is identical
    /// in every mode; only the editor's presentation changes.
    @Published private(set) var editorMode: EditorMode
    @Published private(set) var statistics = DocumentStatistics(lineCount: 0, wordCount: 0, utf8ByteCount: 0)
    let find = FindController()

    /// ⇧⌘P temporarily leaves Panels; this remembers what to return to.
    private var lastNonPanelsMode: EditorMode

    /// Called when the document gains/loses a file identity (open, Save As,
    /// Move to Trash) so the workspace can update recents and restoration.
    var onFileIdentityChanged: (() -> Void)?
    /// Called after any user-visible state change.
    var onChange: (() -> Void)?
    /// Called after the window has been allowed to close.
    var onClosed: (() -> Void)?

    private let workspace: WorkspaceCoordinator?
    private let io = MarkdownFileIO()
    private let recoveryStore: RecoveryStore
    private var baseline: FileFingerprint?
    private var untitledID = UUID()
    private var restoredDocumentID: String?
    private let statsQueue = DispatchQueue(label: "com.ryanpaperclip.markdownnotepad.stats", qos: .utility)
    private var statsWork: DispatchWorkItem?
    private var statsGeneration = 0
    private var idleSnapshotTimer: Timer?
    private var periodicSnapshotTimer: Timer?
    private var isLoading = false
    private weak var window: NSWindow?
    private var titleBarController: TitleBarController?
    private var closeGuard: WindowCloseGuard?

    init(
        workspace: WorkspaceCoordinator? = nil,
        openURL: URL? = nil,
        recoveredSnapshot: RecoverySnapshot? = nil,
        recoverSnapshot: Bool = false,
        recoveryStore: RecoveryStore = RecoveryStore(directory: RecoveryStore.defaultDirectory()),
        initialMode: EditorMode = .panels
    ) {
        self.workspace = workspace
        self.recoveryStore = recoveryStore
        self.state = DocumentDirtyState()
        let initialFormat = TextFileFormat()
        self.format = initialFormat
        self.formatLabel = initialFormat.label
        self.editorMode = initialMode
        self.lastNonPanelsMode = initialMode == .panels ? .plainText : initialMode
        find.onHighlightsChanged = { [weak self] in
            self?.textViewController?.highlighter.reapplyForeground()
        }

        if let openURL {
            load(url: openURL)
        } else if let recoveredSnapshot {
            restore(recoveredSnapshot)
        } else if recoverSnapshot, let snapshot = (try? recoveryStore.loadAll())?.first {
            restore(snapshot)
        }
        refreshStatistics(immediately: true)
    }

    // MARK: - Presentation

    var text: String { state.text }
    var fileURL: URL? { state.fileURL }
    var isDirty: Bool { state.isDirty }
    var displayName: String { fileURL?.lastPathComponent ?? untitledName ?? "Untitled" }
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
        refreshStatistics()
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
        restoredDocumentID = nil
        untitledName = nil
        find.textDidChange()
        refreshStatistics(immediately: true)
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
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? untitledName ?? "Untitled.md"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            let textFile = TextFile(text: text, format: format)
            let fingerprint = try io.saveAs(textFile, to: destination)
            let previousIdentity = recoveryIdentity
            baseline = fingerprint
            state.markSaved(at: destination)
            untitledName = nil
            recoveredFromCrash = false
            restoredDocumentID = nil
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
            try writeCurrentText(to: url, conflictPolicy: conflictPolicy)
            state.markSaved()
            recoveredFromCrash = false
            restoredDocumentID = nil
            stopSnapshots()
            deleteRecoverySnapshot()
            onFileIdentityChanged?()
            notifyChanged()
        } catch MarkdownCoreError.externalChange {
            if !FileManager.default.fileExists(atPath: url.path) {
                presentMissingFileSaveAs(url: url)
            } else {
                presentConflictPrompt(url: url)
            }
        } catch MarkdownCoreError.permissionDenied {
            presentReadOnlySaveAs(url: url)
        } catch {
            present(error)
        }
    }

    /// File changed on disk. Never silently overwrite; offer the four
    /// documented choices. This is an NSAlert (like the other document
    /// prompts) so every button is reachable by keyboard and VoiceOver.
    private func presentConflictPrompt(url: URL) {
        let alert = NSAlert()
        alert.messageText = "File changed on disk"
        alert.informativeText = "“\(url.lastPathComponent)” was changed by another app after you opened it. Choose how to continue."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reload")
        alert.addButton(withTitle: "Overwrite")
        alert.addButton(withTitle: "Save As…")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            reloadFromDisk()
        case .alertSecondButtonReturn:
            overwriteWithCurrentText()
        case .alertThirdButtonReturn:
            saveAs()
        default:
            break
        }
    }

    /// A read-only volume or folder is a save failure, not a crash: keep the
    /// text and guide the user to a writable destination.
    private func presentReadOnlySaveAs(url: URL) {
        let alert = NSAlert()
        alert.messageText = "“\(url.lastPathComponent)” can’t be saved here."
        alert.informativeText = "The folder or disk is read-only, or you don’t have permission to change it. Your text is still here — save it somewhere writable to keep it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save As…")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            saveAs()
        }
    }


    private func writeCurrentText(to url: URL, conflictPolicy: ConflictPolicy) throws {
        let textFile = TextFile(text: text, format: format)
        baseline = try io.save(textFile, to: url, baseline: baseline, conflictPolicy: conflictPolicy)
    }

    // MARK: - Rename / save location

    /// Commits the inline title-bar rename.
    ///
    /// For a file-backed document the bytes are moved to the new `.md` name in
    /// the same folder; for an untitled document the name is recorded and used
    /// on the next save. Returns `false` (after presenting the reason) when the
    /// name is invalid or the destination already exists.
    @discardableResult
    func renameDocument(to proposedName: String) -> Bool {
        guard let filename = MarkdownFilename.normalized(proposedName) else {
            presentInvalidFilename()
            return false
        }

        guard let currentURL = fileURL else {
            untitledName = filename
            notifyChanged()
            return true
        }

        let destination = currentURL.deletingLastPathComponent().appendingPathComponent(filename)
        if MarkdownFilename.isSameFile(currentURL, destination) {
            untitledName = nil
            notifyChanged()
            return true
        }

        do {
            try relocate(to: destination)
            return true
        } catch {
            present(error)
            return false
        }
    }

    /// Saves or moves this document into `folder`, keeping the current name.
    /// The caller has already confirmed the destination with the user.
    @discardableResult
    func moveDocument(toFolder folder: URL) -> Bool {
        let filename = fileURL?.lastPathComponent ?? untitledName ?? "Untitled.md"
        let destination = folder.appendingPathComponent(filename)
        do {
            if fileURL == nil {
                try saveNewDocument(at: destination)
            } else {
                try relocate(to: destination)
            }
            return true
        } catch {
            present(error)
            return false
        }
    }

    func beginRenaming() {
        guard let titleBarController else {
            NSSound.beep()
            return
        }
        titleBarController.beginEditing()
    }

    func presentSaveLocationPicker() {
        guard let titleBarController else {
            NSSound.beep()
            return
        }
        titleBarController.presentSaveLocationPicker()
    }

    /// Moves the current document, saving unsaved text first. Never overwrites:
    /// a name clash is reported and both files are left untouched.
    private func relocate(to destination: URL) throws {
        guard let currentURL = fileURL else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw MarkdownCoreError.destinationExists
        }
        if isDirty {
            try writeCurrentText(to: currentURL, conflictPolicy: .fail)
        }

        let previousIdentity = recoveryIdentity
        try io.move(currentURL, to: destination)
        baseline = try io.fingerprint(of: destination)
        state.markSaved(at: destination)
        untitledName = nil
        recoveredFromCrash = false
        stopSnapshots()
        try? recoveryStore.delete(documentID: previousIdentity)
        deleteRecoverySnapshot()
        onFileIdentityChanged?()
        notifyChanged()
    }

    /// First save for an untitled document, refusing to replace an existing file.
    private func saveNewDocument(at destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw MarkdownCoreError.destinationExists
        }
        let previousIdentity = recoveryIdentity
        let textFile = TextFile(text: text, format: format)
        baseline = try io.saveNew(textFile, to: destination)
        state.markSaved(at: destination)
        untitledName = nil
        recoveredFromCrash = false
        stopSnapshots()
        try? recoveryStore.delete(documentID: previousIdentity)
        deleteRecoverySnapshot()
        onFileIdentityChanged?()
        notifyChanged()
    }

    private func presentInvalidFilename() {
        let alert = NSAlert()
        alert.messageText = "Enter a valid file name."
        alert.informativeText = "Use a single file name without slashes or colons. Markdown documents keep a .md extension."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
            untitledName = nil
            recoveredFromCrash = false
            restoredDocumentID = nil
            find.textDidChange()
            refreshStatistics(immediately: true)
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

    var isPreviewVisible: Bool { editorMode == .panels }

    var modeLabel: String { editorMode.title }

    /// Switches presentation without touching the document text. The last
    /// chosen mode becomes the app-wide default for new windows and relaunches.
    func setEditorMode(_ mode: EditorMode) {
        guard mode != editorMode else { return }
        if mode != .panels {
            lastNonPanelsMode = mode
        }
        editorMode = mode
        workspace?.recordEditorMode(mode)
        notifyChanged()
    }

    /// ⇧⌘P keeps its M3 meaning: showing/hiding the preview is Panels on/off.
    func togglePreview() {
        if editorMode == .panels {
            setEditorMode(lastNonPanelsMode)
        } else {
            setEditorMode(.panels)
        }
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

    func applyFormatting(_ action: MarkdownFormattingAction) {
        textViewController?.apply(action)
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
        if titleBarController == nil {
            titleBarController = TitleBarController(window: window, session: self)
        }
        refreshWindowChrome()
    }

    func refreshWindowChrome() {
        window?.representedURL = fileURL
        window?.isDocumentEdited = isDirty
        window?.title = windowTitle
        titleBarController?.update()
    }

    /// Brings this document's window to the front (used when the same file is
    /// opened again from Finder while it is already open).
    func focusWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Recovery

    private var recoveryIdentity: String {
        if let fileURL {
            return RecoveryStore.documentID(for: fileURL)
        }
        return restoredDocumentID ?? RecoveryStore.documentID(forUntitled: untitledID)
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

    /// Restores one specific snapshot. The workspace owns snapshot discovery so
    /// every unsaved document gets its own window instead of all sessions
    /// racing for the first file in the recovery folder.
    func restore(_ snapshot: RecoverySnapshot) {
        isLoading = true
        state.load(text: snapshot.text, fileURL: snapshot.fileURL.map { URL(fileURLWithPath: $0) })
        state.markRecovered()
        isLoading = false
        format = snapshot.format
        formatLabel = format.label
        baseline = snapshot.baseline
        untitledName = nil
        recoveredFromCrash = true
        restoredDocumentID = snapshot.documentID
        startPeriodicSnapshots()
        refreshStatistics(immediately: true)
    }

    // MARK: - Statistics

    /// Recomputes word/line counts off the main thread. A 10 MB document takes
    /// long enough that doing this inside `body` on every keystroke would make
    /// typing feel heavy, so results are debounced and generation-checked.
    private func refreshStatistics(immediately: Bool = false) {
        statsGeneration += 1
        let generation = statsGeneration
        let snapshot = text
        statsWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            let statistics = MarkdownDocument(text: snapshot).statistics
            DispatchQueue.main.async {
                guard let self, generation == self.statsGeneration else { return }
                self.statistics = statistics
            }
        }
        statsWork = work
        statsQueue.asyncAfter(deadline: .now() + (immediately ? 0 : 0.2), execute: work)
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
}
