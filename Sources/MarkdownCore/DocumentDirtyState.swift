import Foundation

/// Foundation-only dirty-state machine behind the window dirty dot, the
/// save prompts, and Revert.
///
/// "Dirty" means the editing text differs from the last successfully loaded or
/// saved text. File identity is tracked separately so a Save As can change the
/// URL without fabricating an edit.
public struct DocumentDirtyState: Equatable, Sendable {
    public private(set) var text: String
    public private(set) var savedText: String
    public private(set) var fileURL: URL?
    /// Set for text restored from a crash snapshot, where the on-disk content
    /// is deliberately different from the recovered text.
    private var forcedDirty: Bool

    public init(text: String = "", fileURL: URL? = nil, forcedDirty: Bool = false) {
        self.text = text
        self.savedText = text
        self.fileURL = fileURL
        self.forcedDirty = forcedDirty
    }

    public var isDirty: Bool {
        forcedDirty || text != savedText
    }

    /// Marks restored text as unsaved so close/quit prompts fire.
    public mutating func markRecovered() {
        forcedDirty = true
    }

    public var displayName: String {
        fileURL?.lastPathComponent ?? "Untitled"
    }

    /// Applies loaded file contents and resets the saved baseline.
    public mutating func load(text: String, fileURL: URL?) {
        self.text = text
        self.savedText = text
        self.fileURL = fileURL
        forcedDirty = false
    }

    /// Records an edit. Returns `false` when the text is unchanged.
    @discardableResult
    public mutating func edit(_ newText: String) -> Bool {
        guard newText != text else { return false }
        text = newText
        return true
    }

    /// Marks the current text as saved, optionally at a new location.
    public mutating func markSaved(at fileURL: URL? = nil) {
        savedText = text
        forcedDirty = false
        if let fileURL {
            self.fileURL = fileURL
        }
    }

    /// Restores the text to the last saved content (Revert).
    public mutating func revert() {
        text = savedText
        forcedDirty = false
    }

    /// Replaces the document with a brand new untitled buffer.
    public mutating func reset() {
        text = ""
        savedText = ""
        fileURL = nil
        forcedDirty = false
    }
}
