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
    private let modeStore: EditorModeStore
    private let isUITesting: Bool
    private var pendingURLs: [URL] = []
    private var sessions: [WeakSession] = []
    private var didLoadRestoration = false
    private var didSpawnRestorationWindows = false
    private var isFirstSession = true

    /// Installed by the first window so commands can ask SwiftUI to open a new
    /// editor window.
    var openWindowHandler: ((String) -> Void)?

    private init() {
        let testing = ProcessInfo.processInfo.environment["MARKDOWN_NOTEPAD_UI_TESTING"] == "1"
        isUITesting = testing
        let supportOverride = ProcessInfo.processInfo.environment["MARKDOWN_NOTEPAD_SUPPORT_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let base: URL?
        if let supportOverride {
            base = supportOverride
        } else if testing {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("MarkdownNotepadUITests", isDirectory: true)
                .appendingPathComponent(ProcessInfo.processInfo.processIdentifier.description, isDirectory: true)
        } else {
            base = nil
        }
        recentStore = RecentDocumentsStore(
            fileURL: base?.appendingPathComponent("RecentDocuments.json")
                ?? RecentDocumentsStore.defaultFileURL()
        )
        restorationStore = SessionRestorationStore(
            fileURL: base?.appendingPathComponent("OpenDocuments.json")
                ?? SessionRestorationStore.defaultFileURL()
        )
        modeStore = EditorModeStore(
            fileURL: base?.appendingPathComponent("EditorMode.json")
                ?? EditorModeStore.defaultFileURL()
        )
        recentDocuments = testing ? [] : recentStore.load()
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
        }
        let recover = isFirstSession && pendingURLs.isEmpty && !isUITesting
        isFirstSession = false
        return makeSession(recoverSnapshot: recover)
    }

    private func makeSession(recoverSnapshot: Bool) -> DocumentSession {
        let url = pendingURLs.isEmpty ? nil : pendingURLs.removeFirst()
        let session = DocumentSession(
            workspace: self,
            openURL: url,
            recoverSnapshot: recoverSnapshot && url == nil,
            initialMode: defaultEditorMode
        )
        register(session)
        return session
    }

    /// Mode used by new windows and restored after relaunch.
    var defaultEditorMode: EditorMode {
        modeStore.load() ?? EditorMode.fallback
    }

    /// Persists the last user-chosen mode as the app-wide default.
    func recordEditorMode(_ mode: EditorMode) {
        try? modeStore.save(mode)
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
        return pendingURLs.count
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

    // MARK: - Reopen

    /// Dock click / re-open while the app is already running. Bring existing
    /// work forward instead of stacking duplicate blank windows; open exactly
    /// one blank editor when every window has been closed.
    func handleReopen() {
        if let session = liveSessions.first {
            session.focusWindow()
            return
        }
        openWindowHandler?(Self.editorWindowID)
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

        File: ⌘N new window · ⌘O open · ⌘S save · ⇧⌘S save as · ⌘R rename · ⇧⌘M save location · ⌘W close
        Edit: ⌘F find · ⌥⌘F find and replace · ⌘G next match · ⌘L go to line
        View: modes ⌃⌘1 plain · ⌃⌘2 panels · ⌃⌘3 WYSIWYG, preview ⇧⌘P,
              word wrap, zoom, full screen
        Window: tab overview · merge all windows

        Double-click a window title to rename the document, or use the chevron
        beside the title to choose its folder. Existing files are never
        overwritten silently.

        Files are saved as plain UTF-8 text. Markdown syntax is never rewritten.
        The last editor mode you use becomes the default for new windows.
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
