import AppKit
import MarkdownPreview
import SwiftUI
import WebKit

/// Read-only rendered GFM preview hosted in a `WKWebView`.
///
/// JavaScript is disabled at the configuration level, navigation is limited to
/// the initial load and in-page anchors, and every link activation is handed to
/// the user's default browser. Rendered HTML itself carries a strict CSP and
/// the renderer escapes raw HTML, so the preview cannot execute source scripts
/// or fetch remote resources.
struct MarkdownPreviewView: NSViewRepresentable {
    let text: String
    let documentURL: URL?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.setAccessibilityIdentifier("preview")
        webView.setAccessibilityLabel("Rendered Markdown preview")
        webView.setAccessibilityHelp("Read-only rendered preview of the Markdown in the editor.")
        webView.underPageBackgroundColor = .textBackgroundColor
        context.coordinator.webView = webView
        context.coordinator.update(text: text, documentURL: documentURL, immediate: true)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(text: text, documentURL: documentURL)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.cancel()
        webView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        private var lastText: String?
        private var lastBaseURL: URL?
        private var debounce: DispatchWorkItem?
        private var pendingScrollFraction: CGFloat?
        private var isRestoringScroll = false
        private let renderQueue = DispatchQueue(
            label: "com.ryanpaperclip.markdownnotepad.preview",
            qos: .userInitiated
        )
        private var generation = 0

        func cancel() {
            debounce?.cancel()
            debounce = nil
            generation += 1
        }

        func update(text: String, documentURL: URL?, immediate: Bool = false) {
            let baseURL = documentURL?.deletingLastPathComponent()
            guard text != lastText || baseURL != lastBaseURL else { return }
            lastText = text
            lastBaseURL = baseURL
            captureScrollFraction()

            debounce?.cancel()
            generation += 1
            let renderGeneration = generation
            let name = baseURL?.lastPathComponent ?? "Preview"
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let html = MarkdownPreviewRenderer.documentHTML(markdown: text, title: name)
                DispatchQueue.main.async {
                    guard renderGeneration == self.generation, let webView = self.webView else { return }
                    webView.loadHTMLString(html, baseURL: baseURL)
                }
            }
            debounce = work
            if immediate {
                renderQueue.async(execute: work)
            } else {
                renderQueue.asyncAfter(deadline: .now() + 0.15, execute: work)
            }
        }

        private func captureScrollFraction() {
            guard let webView,
                  let scrollView = scrollView(of: webView),
                  let documentView = scrollView.documentView else { return }
            let height = documentView.bounds.height
            guard height > 0 else { return }
            pendingScrollFraction = max(0, scrollView.contentView.bounds.origin.y / height)
        }

        private func restoreScrollIfNeeded() {
            guard let webView, let fraction = pendingScrollFraction else { return }
            pendingScrollFraction = nil
            isRestoringScroll = true
            DispatchQueue.main.async {
                guard let scrollView = self.scrollView(of: webView),
                      let documentView = scrollView.documentView else {
                    self.isRestoringScroll = false
                    return
                }
                let height = documentView.bounds.height
                let viewport = scrollView.contentView.bounds.height
                let maximum = max(0, height - viewport)
                let target = min(maximum, fraction * height)
                scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: target))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                self.isRestoringScroll = false
            }
        }

        // MARK: - WKNavigationDelegate

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            switch navigationAction.navigationType {
            case .other, .reload:
                decisionHandler(.allow)
            case .linkActivated:
                if navigationAction.request.url?.fragment != nil {
                    decisionHandler(.allow)
                } else {
                    openExternally(navigationAction.request.url)
                    decisionHandler(.cancel)
                }
            case .backForward, .formSubmitted, .formResubmitted:
                decisionHandler(.cancel)
            @unknown default:
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            restoreScrollIfNeeded()
        }

        /// WKWebView on macOS keeps its scroll view in the private view
        /// hierarchy rather than exposing an iOS-style `scrollView` property.
        private func scrollView(of webView: WKWebView) -> NSScrollView? {
            var queue = webView.subviews
            while !queue.isEmpty {
                let view = queue.removeFirst()
                if let scrollView = view as? NSScrollView {
                    return scrollView
                }
                queue.append(contentsOf: view.subviews)
            }
            return nil
        }

        private func openExternally(_ url: URL?) {
            guard let url, let scheme = url.scheme?.lowercased() else { return }
            guard ["http", "https", "mailto"].contains(scheme) else { return }
            NSWorkspace.shared.open(url)
        }
    }
}
