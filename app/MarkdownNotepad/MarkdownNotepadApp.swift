import AppKit
import SwiftUI

private struct DocumentSessionFocusedKey: FocusedValueKey {
    typealias Value = DocumentSession
}

extension FocusedValues {
    var documentSession: DocumentSession? {
        get { self[DocumentSessionFocusedKey.self] }
        set { self[DocumentSessionFocusedKey.self] = newValue }
    }
}

@main
struct MarkdownNotepadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Markdown Notepad", id: WorkspaceCoordinator.editorWindowID) {
            DocumentWindowView()
        }
        .commands {
            DocumentCommands()
        }
    }
}

struct DocumentCommands: Commands {
    @ObservedObject private var workspace = WorkspaceCoordinator.shared
    @FocusedValue(\.documentSession) private var session

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") {
                workspace.requestNewWindow()
            }
            .keyboardShortcut("n")

            Button("Open…") {
                workspace.presentOpenPanel(focusedSession: session)
            }
            .keyboardShortcut("o")

            Menu("Open Recent") {
                if workspace.recentDocuments.isEmpty {
                    Text("No Recent Documents")
                } else {
                    ForEach(workspace.recentDocuments, id: \.path) { document in
                        Button(document.displayName) {
                            workspace.openRecent(document, in: session)
                        }
                        .disabled(workspace.isMissing(document))
                        .help(workspace.isMissing(document)
                              ? "The file “\(document.path)” is missing"
                              : document.path)
                    }
                    Divider()
                    Button("Clear Menu") {
                        workspace.clearRecents()
                    }
                }
            }

            Divider()

            Button("Close") {
                if let session {
                    session.requestClose()
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w")
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                session?.save()
            }
            .keyboardShortcut("s")
            .disabled(session == nil)

            Button("Save As…") {
                session?.saveAs()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(session == nil)

            Button("Rename…") {
                session?.beginRenaming()
            }
            .keyboardShortcut("r")
            .disabled(session == nil)

            Button("Choose Save Location…") {
                session?.presentSaveLocationPicker()
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(session == nil)

            Button("Revert to Saved") {
                session?.revertToSaved()
            }
            .disabled(session?.fileURL == nil)

            Divider()

            Button("Move to Trash") {
                session?.moveToTrash()
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(session?.fileURL == nil)
        }

        CommandGroup(after: .pasteboard) {
            Divider()

            Button("Find…") {
                session?.showFind(replace: false)
            }
            .keyboardShortcut("f")
            .disabled(session == nil)

            Button("Find and Replace…") {
                session?.showFind(replace: true)
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(session == nil)

            Button("Find Next") {
                session?.findNext()
            }
            .keyboardShortcut("g")
            .disabled(session == nil)

            Button("Find Previous") {
                session?.findPrevious()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(session == nil)

            Divider()

            Button("Go to Line…") {
                session?.goToLine()
            }
            .keyboardShortcut("l")
            .disabled(session == nil)
        }

        CommandGroup(after: .toolbar) {
            Divider()

            Toggle("Preview", isOn: Binding(
                get: { session?.isPreviewVisible ?? false },
                set: { _ in session?.togglePreview() }
            ))
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(session == nil)

            Divider()

            Toggle("Word Wrap", isOn: Binding(
                get: { session?.wordWrap ?? false },
                set: { _ in session?.toggleWordWrap() }
            ))
            .disabled(session == nil)

            Divider()

            Button("Zoom In") {
                session?.zoomIn()
            }
            .keyboardShortcut("+", modifiers: [.command])
            .disabled(session == nil)

            Button("Zoom Out") {
                session?.zoomOut()
            }
            .keyboardShortcut("-", modifiers: [.command])
            .disabled(session == nil)

            Button("Actual Size") {
                session?.actualSize()
            }
            .keyboardShortcut("0", modifiers: [.command])
            .disabled(session == nil)

            Divider()

            Button("Enter Full Screen") {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
        }

        CommandGroup(after: .windowArrangement) {
            Divider()

            Button("Show Tab Overview") {
                NSApp.sendAction(#selector(NSWindow.toggleTabOverview(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("\\", modifiers: [.command, .shift])

            Button("Merge All Windows") {
                NSApp.sendAction(#selector(NSWindow.mergeAllWindows(_:)), to: nil, from: nil)
            }
        }

        CommandGroup(replacing: .help) {
            Button("Markdown Notepad Help") {
                workspace.showHelp()
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        if ProcessInfo.processInfo.environment["MARKDOWN_NOTEPAD_FORCE_DARK"] == "1" {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        WorkspaceCoordinator.shared.writeOpenProbeIfRequested()
        #endif
    }

    /// Finder double-click, Open With, a Dock drop, and
    /// `open -a "Markdown Notepad" file.md` all arrive here.
    func application(_ application: NSApplication, open urls: [URL]) {
        WorkspaceCoordinator.shared.receiveOpen(urls)
    }

    /// Legacy fallback for AppKit versions that still send the single-file
    /// variant instead of `application(_:open:)`.
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        WorkspaceCoordinator.shared.receiveOpen([URL(fileURLWithPath: filename)])
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        WorkspaceCoordinator.shared.prepareForTermination() ? .terminateNow : .terminateCancel
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
