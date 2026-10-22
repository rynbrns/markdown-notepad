import AppKit
import Foundation
import MarkdownCore
import SwiftUI
import UniformTypeIdentifiers

/// App-wide document coordination: recents, workspace restoration, and the
/// open/new-window actions used by the menu bar.
final class WorkspaceCoordinator: ObservableObject {
    static let shared = WorkspaceCoordinator()

    /// Window scene id shared by every editor window.
    static let editorWindowID = "editor"

    @Published private(set) var recentDocuments: [RecentDocument] = []

    private let recentStore: RecentDocumentsStore
    private let restorationStore: SessionRestorationStore
    private let recoveryStore: RecoveryStore
    private let supportDirectory: URL
    private let isUITesting: Bool
    private var pendingURLs: [URL] = []
    private var pendingSnapshots: [RecoverySnapshot] = []
    private var sessions: [WeakSession] = []
    private var didLoadRestoration = false
    private var didSpawnRestorationWindows = false

    /// Installed by the first window so commands can ask SwiftUI to open a new
    /// editor window.
    var openWindowHandler: ((String) -> Void)?

    private init() {
        let environment = ProcessInfo.processInfo.environment
        let testing = environment["MARKDOWN_NOTEPAD_UI_TESTING"] == "1"
        isUITesting = testing

        // One state directory holds recents, restoration, and recovery so a UI
        // test (or a future sandboxed container) can isolate all three and a
        // force-quit test can relaunch against the same directory.
        let base: URL
        if let override = environment["MARKDOWN_NOTEPAD_SUPPORT_DIR"], !override.isEmpty {
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else if testing {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("MarkdownNotepadUITests", isDirectory: true)
                .appendingPathComponent(ProcessInfo.processInfo.processIdentifier.description, isDirectory: true)
        } else {
            base = RecentDocumentsStore.defaultFileURL().deletingLastPathComponent()
        }
        supportDirectory = base
        recentStore = RecentDocumentsStore(fileURL: base.appendingPathComponent("RecentDocuments.json"))
        restorationStore = SessionRestorationStore(fileURL: base.appendingPathComponent("OpenDocuments.json"))
        recoveryStore = RecoveryStore(directory: base.appendingPathComponent("Recovery", isDirectory: true))
        recentDocuments = recentStore.load()
    }

    // MARK: - Session lifecycle

    func makeInitialSession() -> DocumentSession {
        if !didLoadRestoration {
            didLoadRestoration = true
            if !isUITesting {
                let restored = restorationStore.load()
                // A file opened from Finder before the first window was created
                // takes precedence over the restored session; the restored
                // windows follow it.
                pendingURLs.append(contentsOf: restored.filter { !pendingURLs.contains($0) })
            }
            if let openPath = ProcessInfo.processInfo.environment["MARKDOWN_NOTEPAD_OPEN_FILE"], !openPath.isEmpty {
                let url = URL(fileURLWithPath: openPath).standardizedFileURL
                pendingURLs.removeAll { $0.standardizedFileURL == url }
                pendingURLs.insert(url, at: 0)
            }

            pendingSnapshots = (try? recoveryStore.loadAll()) ?? []
            // A snapshot for a file also listed in restoration carries unsaved
            // text; restoring it must win over reopening the stale file bytes.
            if !pendingSnapshots.isEmpty {
                let snapshotPaths = Set(pendingSnapshots.compactMap(\.fileURL))
                pendingURLs.removeAll { snapshotPaths.contains($0.standardizedFileURL.path) }
            }
        }
        return makeSession()
    }

    private func makeSession() -> DocumentSession {
        let snapshot = pendingSnapshots.isEmpty ? nil : pendingSnapshots.removeFirst()
        let url = snapshot == nil && !pendingURLs.isEmpty ? pendingURLs.removeFirst() : nil
        let session = DocumentSession(
            workspace: self,
            openURL: url,
            recoveredSnapshot: snapshot,
            recoveryStore: recoveryStore
        )
        register(session)
        if let path = snapshot?.fileURL {
            recordRecent(URL(fileURLWithPath: path))
        }
        return session
    }

    private func register(_ session: DocumentSession) {
        sessions.append(WeakSession(session))
        session.onFileIdentityChanged = { [weak self, weak session] in
            guard let self else { return }
            if let url = session?.fileURL {
                self.recordRecent(url)
            }
            self.persistOpenDocuments()
        }
        session.onClosed = { [weak self, weak session] in
            self?.unregister(session)
        }
    }

    private func unregister(_ session: DocumentSession?) {
        guard let session else { return }
        sessions.removeAll { $0.value == nil || $0.value === session }
        persistOpenDocuments()
    }

    private var liveSessions: [DocumentSession] {
        sessions.compactMap(\.value)
    }

    // MARK: - Restoration

    /// The number of extra windows the first window should open to restore the
    /// previous session. Only the first caller gets a non-zero result.
    func consumeRestorationSpawnCount() -> Int {
        guard !didSpawnRestorationWindows else { return 0 }
        didSpawnRestorationWindows = true
        return pendingSnapshots.count + pendingURLs.count
    }

    func persistOpenDocuments() {
        let urls = liveSessions.compactMap(\.fileURL)
        try? restorationStore.save(urls)
    }

    // MARK: - Files opened by Launch Services

    /// Handles a `.md` file opened from Finder (double-click, Open With, Dock
    /// drop) or with `open -a "Markdown Notepad" file.md`.
    ///
    /// The file is loaded into an existing pristine window when there is one,
    /// so launching the app by opening a file never leaves an extra blank
    /// window behind. Additional files each get their own window.
    func receiveOpen(_ urls: [URL]) {
        var queue = urls
            .map(\.standardizedFileURL)
            .filter { !pendingURLs.contains($0) }
        guard !queue.isEmpty else { return }

        queue.removeAll { url in
            guard let existing = liveSessions.first(where: {
                $0.fileURL?.standardizedFileURL == url
            }) else { return false }
            existing.focusWindow()
            return true
        }
        guard !queue.isEmpty else { return }

        if let blank = liveSessions.first(where: { $0.isPristineUntitled }) {
            blank.load(url: queue.removeFirst())
            guard !queue.isEmpty else { return }
        }

        pendingURLs.append(contentsOf: queue)
        guard let openWindowHandler else { return }
        for _ in 0..<queue.count {
            openWindowHandler(Self.editorWindowID)
        }
    }

    // MARK: - Actions

    func requestNewWindow() {
        openWindowHandler?(Self.editorWindowID)
    }

    func requestNewWindow(opening url: URL) {
        pendingURLs.append(url)
        openWindowHandler?(Self.editorWindowID)
    }

    func presentOpenPanel(focusedSession: DocumentSession?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.textContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let focusedSession {
            focusedSession.load(url: url)
        } else {
            requestNewWindow(opening: url)
        }
    }

    func openRecent(_ document: RecentDocument, in session: DocumentSession?) {
        if let session {
            session.load(url: document.url)
        } else {
            requestNewWindow(opening: document.url)
        }
    }

    func recordRecent(_ url: URL) {
        guard let documents = try? recentStore.add(url) else { return }
        recentDocuments = documents
    }

    func clearRecents() {
        recentStore.clear()
        recentDocuments = []
    }

    func isMissing(_ document: RecentDocument) -> Bool {
        !FileManager.default.fileExists(atPath: document.path)
    }

    // MARK: - Termination

    func prepareForTermination() -> Bool {
        for session in liveSessions where !session.prepareForTermination() {
            return false
        }
        persistOpenDocuments()
        return true
    }

    func showHelp() {
        let alert = NSAlert()
        alert.messageText = "Markdown Notepad"
        alert.informativeText = """
        A plain-text Markdown editor.

        File: ⌘N new window · ⌘O open · ⌘S save · ⇧⌘S save as · ⌘W close
        Edit: ⌘F find · ⌥⌘F find and replace · ⌘G next match · ⌘L go to line
        View: preview ⇧⌘P, word wrap, zoom, full screen
        Window: tab overview · merge all windows

        Files are saved as plain UTF-8 text. Markdown syntax is never rewritten.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    #if DEBUG
    /// CI verification hook. `-openProbe <path>` makes a Debug build write the
    /// windows it actually ended up with once Launch Services has delivered any
    /// file-open event, so CI can prove a launched-by-file run has one window
    /// and no blank leftover.
    func writeOpenProbeIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "openProbe"), !path.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self else { return }
            let sessions: [[String: Any]] = self.liveSessions.map { session in
                [
                    "path": session.fileURL?.path ?? NSNull(),
                    "title": session.displayName,
                    "dirty": session.isDirty
                ]
            }
            let payload: [String: Any] = [
                "sessionCount": sessions.count,
                "visibleWindowCount": NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }.count,
                "sessions": sessions
            ]
            guard let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            ) else { return }
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
    #endif

    private static var textContentTypes: [UTType] {
        var types: [UTType] = []
        if let markdown = UTType(filenameExtension: "md") {
            types.append(markdown)
        }
        types.append(.plainText)
        return types
    }
}

private final class WeakSession {
    weak var value: DocumentSession?

    init(_ value: DocumentSession) {
        self.value = value
    }
}
