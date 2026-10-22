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

        func cancel() {
            debounce?.cancel()
            debounce = nil
        }

        func update(text: String, documentURL: URL?, immediate: Bool = false) {
            let baseURL = documentURL?.deletingLastPathComponent()
            guard text != lastText || baseURL != lastBaseURL else { return }
            lastText = text
            lastBaseURL = baseURL

            debounce?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.render(text: text, baseURL: baseURL)
            }
            debounce = work
            if immediate {
                DispatchQueue.main.async(execute: work)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            }
        }

        private func render(text: String, baseURL: URL?) {
            guard let webView else { return }
            captureScrollFraction()
            let name = baseURL?.lastPathComponent ?? "Preview"
            let html = MarkdownPreviewRenderer.documentHTML(markdown: text, title: name)
            webView.loadHTMLString(html, baseURL: baseURL)
        }

        private func captureScrollFraction() {
            guard let webView else { return }
            let scrollView = webView.scrollView
            guard let documentView = scrollView.documentView else { return }
            let height = documentView.bounds.height
            guard height > 0 else { return }
            pendingScrollFraction = max(0, scrollView.contentOffset.y / height)
        }

        private func restoreScrollIfNeeded() {
            guard let webView, let fraction = pendingScrollFraction else { return }
            pendingScrollFraction = nil
            isRestoringScroll = true
            DispatchQueue.main.async {
                let scrollView = webView.scrollView
                guard let documentView = scrollView.documentView else {
                    self.isRestoringScroll = false
                    return
                }
                let height = documentView.bounds.height
                let viewport = scrollView.contentView.bounds.height
                let maximum = max(0, height - viewport)
                let target = min(maximum, fraction * height)
                scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentOffset.x, y: target))
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

        private func openExternally(_ url: URL?) {
            guard let url, let scheme = url.scheme?.lowercased() else { return }
            guard ["http", "https", "mailto"].contains(scheme) else { return }
            NSWorkspace.shared.open(url)
        }
    }
}
