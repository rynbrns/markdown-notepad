import MarkdownCore
import SwiftUI

/// Root view for one editor window.
struct DocumentWindowView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var workspace = WorkspaceCoordinator.shared
    @StateObject private var session: DocumentSession

    init() {
        _session = StateObject(wrappedValue: WorkspaceCoordinator.shared.makeInitialSession())
    }

    var body: some View {
        ContentView(session: session, find: session.find)
            .frame(minWidth: 640, minHeight: 420)
            .focusedSceneValue(\.documentSession, session)
            .background(
                WindowAccessor { window in
                    session.attach(window: window)
                }
            )
            .task {
                workspace.openWindowHandler = { id in
                    openWindow(id: id)
                }
                let extraWindows = workspace.consumeRestorationSpawnCount()
                for _ in 0..<extraWindows {
                    openWindow(id: WorkspaceCoordinator.editorWindowID)
                }
            }
    }
}

struct ContentView: View {
    @ObservedObject var session: DocumentSession
    @ObservedObject var find: FindController

    private var document: MarkdownDocument {
        MarkdownDocument(text: session.text)
    }

    var body: some View {
        VStack(spacing: 0) {
            if session.recoveredFromCrash {
                recoveredBanner
                Divider()
            }

            if find.isVisible {
                FindBarView(session: session, controller: find)
                Divider()
            }

            HSplitView {
                MarkdownTextView(session: session)
                    .frame(minWidth: 320)
                if session.editorMode == .panels {
                    MarkdownPreviewView(
                        text: session.text,
                        documentURL: session.previewBaseURL
                    )
                    .frame(minWidth: 320)
                }
            }
            .accessibilityIdentifier(session.editorMode == .panels ? "splitPreview" : "editorSurface")

            Divider()

            statusBar
        }
        .navigationTitle(session.windowTitle)
        .alert(
            "File changed on disk",
            isPresented: Binding(
                get: { session.conflictPrompt != nil },
                set: { isPresented in
                    if !isPresented { session.conflictPrompt = nil }
                }
            ),
            presenting: session.conflictPrompt
        ) { _ in
            Button("Reload") {
                session.conflictPrompt = nil
                session.reloadFromDisk()
            }
            Button("Overwrite") {
                session.conflictPrompt = nil
                session.overwriteWithCurrentText()
            }
            Button("Save As…") {
                session.conflictPrompt = nil
                session.saveAs()
            }
            Button("Cancel", role: .cancel) {
                session.conflictPrompt = nil
            }
        } message: { _ in
            Text("“\(session.displayName)” was changed by another app after you opened it. Choose how to continue.")
        }
    }

    private var recoveredBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.counterclockwise.circle")
            Text("Recovered unsaved text after an unexpected quit.")
            Spacer()
            Button("Dismiss") {
                session.acknowledgeRecovery()
            }
            .buttonStyle(.link)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.15))
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text("\(document.wordCount) words")
            Text("·")
            Text("\(document.lineCount) lines")
            Text("·")
            Text(session.formatLabel)
            Text("·")
            Text(session.modeLabel)
            if session.isPreviewVisible {
                Text("·")
                Text("Preview")
                    .accessibilityIdentifier("previewVisible")
            }
            Spacer()
            EditorModeSwitcher(session: session)
            if session.isDirty {
                Text("Edited")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("dirtyIndicator")
            }
            Text(session.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier("documentName")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
