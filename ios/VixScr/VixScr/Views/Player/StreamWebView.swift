import SwiftUI
import WebKit

/// Renders the streaming server's embed page and enforces the same
/// popup/redirect blocking policy as the Electron main process.
///
/// Electron behaviour being replicated here (main.js):
///   - `setWindowOpenHandler` on every WebContents: only allows
///     `window.open()` / `target="_blank"` navigations to
///     themoviedb.org / tmdb.org (and subdomains); everything else is
///     denied outright.
///   - `will-attach-webview` is blocked entirely (no nested <webview>).
///   - `onHeadersReceived` strips X-Frame-Options / CSP so the embed can be
///     framed at all.
///   - preload.js additionally patches `window.open` in the renderer as a
///     defence-in-depth fallback with the same TMDB allowlist.
///
/// On iOS there's no window.open/BrowserWindow concept — a WKWebView is a
/// single frame. The equivalent surface area is:
///   - `decidePolicyFor navigationAction` — covers same-window redirects
///     (ads/trackers trying to hijack the current page). We cancel any
///     top-level navigation whose destination isn't the streaming host we
///     loaded or a TMDB domain, exactly mirroring the allowlist logic.
///   - `webView(_:createWebViewWith:for:windowFeatures:)` (WKUIDelegate) —
///     covers `window.open()` / `target="_blank"` new-window attempts,
///     which is the direct analogue of `setWindowOpenHandler`. TMDB links
///     are handed to the system browser via `UIApplication.open`; anything
///     else returns `nil`, i.e. denied, exactly like `{ action: 'deny' }`.
///   - JavaScript alert/confirm/beforeunload panels are also blocked from
///     stalling the UI, since ad networks commonly (ab)use these to trap
///     users during redirect attempts.
struct StreamWebView: UIViewRepresentable {
    let url: URL
    var onNewLoad: (() -> Void)?

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.bounces = false
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        context.coordinator.load(url, into: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.currentURL != url else { return }
        context.coordinator.load(url, into: webView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onNewLoad: onNewLoad) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private(set) var currentURL: URL?
        private var allowedHost: String?
        let onNewLoad: (() -> Void)?

        init(onNewLoad: (() -> Void)?) {
            self.onNewLoad = onNewLoad
        }

        func load(_ url: URL, into webView: WKWebView) {
            currentURL = url
            allowedHost = url.host
            onNewLoad?()
            webView.load(URLRequest(url: url))
        }

        /// Blocks redirect/hijack attempts within the same frame. Only the
        /// originally-loaded host (the chosen streaming server) and TMDB
        /// domains are allowed; everything else — ad redirects, affiliate
        /// hops, pop-under targets — is cancelled outright.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            if navigationAction.targetFrame?.isMainFrame != true {
                // Sub-frame navigations (the player's own internal iframes)
                // are left alone; only top-level redirects are policed.
                decisionHandler(.allow)
                return
            }

            if isSameHost(url, as: allowedHost) || isTMDBHost(url) {
                decisionHandler(.allow)
                return
            }

            decisionHandler(.cancel)
        }

        /// Analogue of `setWindowOpenHandler`: any `window.open()` or
        /// `target="_blank"` link. TMDB links open in the system browser
        /// (like `shell.openExternal`); everything else is denied.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url, isTMDBHost(url) {
                UIApplication.shared.open(url)
            }
            return nil
        }

        /// Ad/tracker pages sometimes use `beforeunload`, `alert`, or
        /// `confirm` dialogs to trap navigation. Auto-dismiss instead of
        /// presenting them.
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            completionHandler()
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            completionHandler(false)
        }

        func webViewDidClose(_ webView: WKWebView) {}

        private func isSameHost(_ url: URL, as host: String?) -> Bool {
            guard let host, let candidate = url.host else { return false }
            return candidate == host || candidate.hasSuffix("." + host)
        }

        private func isTMDBHost(_ url: URL) -> Bool {
            guard let host = url.host else { return false }
            return host == "themoviedb.org" || host.hasSuffix(".themoviedb.org")
                || host == "tmdb.org" || host.hasSuffix(".tmdb.org")
        }
    }
}
