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
        let base = testing
            ? FileManager.default.temporaryDirectory
                .appendingPathComponent("MarkdownNotepadUITests", isDirectory: true)
                .appendingPathComponent(ProcessInfo.processInfo.processIdentifier.description, isDirectory: true)
            : nil
        recentStore = RecentDocumentsStore(
            fileURL: base?.appendingPathComponent("RecentDocuments.json")
                ?? RecentDocumentsStore.defaultFileURL()
        )
        restorationStore = SessionRestorationStore(
            fileURL: base?.appendingPathComponent("OpenDocuments.json")
                ?? SessionRestorationStore.defaultFileURL()
        )
        recentDocuments = testing ? [] : recentStore.load()
    }

    // MARK: - Session lifecycle

    func makeInitialSession() -> DocumentSession {
        if !didLoadRestoration {
            didLoadRestoration = true
            pendingURLs = isUITesting ? [] : restorationStore.load()
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
            recoverSnapshot: recoverSnapshot && url == nil
        )
        register(session)
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
        return pendingURLs.count
    }

    func persistOpenDocuments() {
        let urls = liveSessions.compactMap(\.fileURL)
        try? restorationStore.save(urls)
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
