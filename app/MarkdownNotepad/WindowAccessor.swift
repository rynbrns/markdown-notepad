import AppKit
import SwiftUI

/// Resolves the hosting `NSWindow` so the session can install its close guard,
/// dirty dot, and tabbing preference.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowReportingView {
        let view = WindowReportingView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: WindowReportingView, context: Context) {
        nsView.onResolve = onResolve
        nsView.reportIfReady()
    }
}

final class WindowReportingView: NSView {
    var onResolve: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportIfReady()
    }

    func reportIfReady() {
        guard let window else { return }
        onResolve?(window)
    }
}
