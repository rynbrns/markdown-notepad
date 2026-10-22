import AppKit
import Foundation
import MarkdownCore

/// Drives the interactive title bar: an inline, double-click-to-edit document
/// name and a disclosure chevron that opens a save-location popover.
///
/// The native window title is kept in sync for tabs, the Window menu, and
/// VoiceOver, but it is hidden visually so this accessory view can act as the
/// document title next to the traffic lights.
final class TitleBarController: NSObject, NSTextFieldDelegate {
    private weak var window: NSWindow?
    private weak var session: DocumentSession?

    private let accessory = NSTitlebarAccessoryViewController()
    private let container = NSStackView()
    private let nameField = NSTextField(labelWithString: "Untitled")
    private let chevron = NSButton()
    private var popover: NSPopover?
    private var titleDoubleClickMonitor: Any?
    private var isEditing = false
    private var suppressEndEditingCommit = false

    init(window: NSWindow, session: DocumentSession) {
        self.window = window
        self.session = session
        super.init()

        configureTitleBar(in: window)
        configureNameField()
        configureChevron()
        installTitleDoubleClickMonitor()

        update()
    }

    deinit {
        if let titleDoubleClickMonitor {
            NSEvent.removeMonitor(titleDoubleClickMonitor)
        }
    }

    // MARK: - Configuration

    private func configureTitleBar(in window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .automatic

        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 3
        container.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        container.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        container.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        container.addArrangedSubview(chevron)
        container.addArrangedSubview(nameField)

        nameField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            nameField.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])

        accessory.view = container
        accessory.layoutAttribute = .left
        window.addTitlebarAccessoryViewController(accessory)
    }

    private func configureNameField() {
        nameField.font = .systemFont(ofSize: 13, weight: .semibold)
        nameField.textColor = .labelColor
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.usesSingleLineMode = true
        nameField.maximumNumberOfLines = 1
        nameField.isEditable = false
        nameField.isSelectable = false
        nameField.isBezeled = false
        nameField.drawsBackground = false
        nameField.focusRingType = .default
        nameField.delegate = self
        nameField.setAccessibilityIdentifier("titleBarNameField")
        nameField.setAccessibilityLabel("Document name")
        nameField.setAccessibilityHelp("Double-click to rename this document. Press Return to commit or Escape to cancel.")

        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(beginEditing))
        doubleClick.numberOfClicksRequired = 2
        nameField.addGestureRecognizer(doubleClick)
    }

    private func configureChevron() {
        let image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "arrowtriangle.down.fill", accessibilityDescription: nil)
            ?? NSImage()
        chevron.image = image
        chevron.imagePosition = .imageOnly
        chevron.imageScaling = .scaleProportionallyDown
        chevron.isBordered = false
        chevron.bezelStyle = .inline
        chevron.contentTintColor = .secondaryLabelColor
        chevron.target = self
        chevron.action = #selector(presentSaveLocationPicker)
        chevron.toolTip = "Choose where this document is saved"
        chevron.setAccessibilityIdentifier("titleBarSaveLocation")
        chevron.setAccessibilityLabel("Choose save location")
        chevron.setAccessibilityHelp("Shows the current folder and lets you pick where to save this document.")
    }

    private func installTitleDoubleClickMonitor() {
        titleDoubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, let window = self.window,
                  event.window === window,
                  event.clickCount == 2,
                  !window.styleMask.contains(.fullScreen) else {
                return event
            }

            let contentFrame = window.contentView?.frame ?? .zero
            guard event.locationInWindow.y > contentFrame.maxY else { return event }

            if let themeFrame = window.contentView?.superview,
               let hit = themeFrame.hitTest(event.locationInWindow),
               hit.isDescendant(of: self.container) {
                return event
            }

            self.beginEditing()
            return nil
        }
    }

    // MARK: - Public actions

    /// Syncs the title bar with the session's display name.
    func update() {
        guard !isEditing else { return }
        let name = session?.displayName ?? "Untitled"
        nameField.stringValue = name
        nameField.toolTip = name
        nameField.setAccessibilityValue(name)
        chevron.setAccessibilityLabel("Choose save location for \(name)")
    }

    @objc func beginEditing() {
        guard let window, let session, !isEditing else { return }
        isEditing = true
        nameField.stringValue = MarkdownFilename.editableName(for: session.displayName)
        nameField.isEditable = true
        nameField.isSelectable = true
        nameField.isBezeled = true
        nameField.bezelStyle = .roundedBezel
        nameField.drawsBackground = true
        nameField.backgroundColor = .textBackgroundColor
        nameField.textColor = .textColor
        nameField.font = .systemFont(ofSize: 13)
        nameField.setAccessibilityHelp("Type a new file name. Press Return to rename, or Escape to cancel.")
        window.makeFirstResponder(nameField)
        nameField.currentEditor()?.selectAll(nil)
    }

    @objc func presentSaveLocationPicker() {
        guard let session else { return }
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }

        let content = SaveLocationPopoverController(session: session)
        let popover = NSPopover()
        popover.contentViewController = content
        popover.behavior = .transient
        _ = content.view
        popover.contentSize = content.preferredContentSize
        content.popover = popover
        self.popover = popover
        popover.show(relativeTo: chevron.bounds, of: chevron, preferredEdge: .minY)
    }

    // MARK: - Editing

    private func finishEditing(commit: Bool) {
        guard isEditing else { return }
        let proposed = nameField.stringValue
        isEditing = false
        suppressEndEditingCommit = true
        if commit {
            _ = session?.renameDocument(to: proposed)
        }
        window?.makeFirstResponder(nil)
        suppressEndEditingCommit = false
        resetFieldAppearance()
        update()
    }

    private func resetFieldAppearance() {
        nameField.isEditable = false
        nameField.isSelectable = false
        nameField.isBezeled = false
        nameField.drawsBackground = false
        nameField.textColor = .labelColor
        nameField.font = .systemFont(ofSize: 13, weight: .semibold)
        nameField.setAccessibilityHelp("Double-click to rename this document. Press Return to commit or Escape to cancel.")
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finishEditing(commit: true)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishEditing(commit: false)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard isEditing, !suppressEndEditingCommit else { return }
        finishEditing(commit: true)
    }
}

/// Popover content for the title-bar disclosure chevron. Shows the current
/// folder and opens a native `NSOpenPanel` directory picker.
final class SaveLocationPopoverController: NSViewController {
    private weak var session: DocumentSession?
    private let fileValue = NSTextField(labelWithString: "Untitled")
    private let folderValue = NSTextField(labelWithString: "")
    private let chooseButton = NSButton(title: "Choose Folder…", target: nil, action: nil)
    weak var popover: NSPopover?

    init(session: DocumentSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 170))

        let title = NSTextField(labelWithString: "Save location")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let fileCaption = NSTextField(labelWithString: "File")
        fileCaption.font = .systemFont(ofSize: 11)
        fileCaption.textColor = .secondaryLabelColor
        fileValue.font = .systemFont(ofSize: 12)
        fileValue.lineBreakMode = .byTruncatingMiddle
        fileValue.usesSingleLineMode = true
        fileValue.setAccessibilityIdentifier("saveLocationFileName")

        let folderCaption = NSTextField(labelWithString: "Current folder")
        folderCaption.font = .systemFont(ofSize: 11)
        folderCaption.textColor = .secondaryLabelColor
        folderValue.font = .systemFont(ofSize: 12)
        folderValue.lineBreakMode = .byTruncatingMiddle
        folderValue.usesSingleLineMode = true
        folderValue.isSelectable = true
        folderValue.setAccessibilityIdentifier("saveLocationFolder")
        folderValue.setAccessibilityLabel("Current folder")

        chooseButton.target = self
        chooseButton.action = #selector(chooseFolder)
        chooseButton.bezelStyle = .rounded
        chooseButton.keyEquivalent = "\r"
        chooseButton.setAccessibilityIdentifier("saveLocationChooseFolder")
        chooseButton.setAccessibilityHelp("Opens a native folder picker. Existing files are never overwritten.")

        let stack = NSStackView(views: [title, fileCaption, fileValue, folderCaption, folderValue, chooseButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            fileValue.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            folderValue.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            chooseButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])

        view = root
        preferredContentSize = NSSize(width: 380, height: 170)
        refresh()
    }

    private func refresh() {
        guard let session else { return }
        fileValue.stringValue = session.displayName
        fileValue.toolTip = session.displayName
        if let url = session.fileURL {
            let folder = url.deletingLastPathComponent()
            folderValue.stringValue = folder.path
            folderValue.toolTip = folder.path
            folderValue.setAccessibilityValue(folder.path)
        } else {
            folderValue.stringValue = "Not saved yet"
            folderValue.toolTip = "Choose a folder to save this document."
            folderValue.setAccessibilityValue("Not saved yet")
        }
    }

    @objc private func chooseFolder() {
        guard let session else { return }
        popover?.performClose(nil)

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder for “\(session.displayName)”."
        if let folder = session.fileURL?.deletingLastPathComponent() {
            panel.directoryURL = folder
        }
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let isUntitled = session.fileURL == nil
        let alert = NSAlert()
        alert.messageText = isUntitled
            ? "Save “\(session.displayName)” in “\(folder.lastPathComponent)”?"
            : "Move “\(session.displayName)” to “\(folder.lastPathComponent)”?"
        alert.informativeText = """
        \(folder.path)

        Existing files are never overwritten. If this folder already contains a file with the same name, you will be asked to choose another name.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: isUntitled ? "Save Here" : "Move Here")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        session.moveDocument(toFolder: folder)
    }
}
