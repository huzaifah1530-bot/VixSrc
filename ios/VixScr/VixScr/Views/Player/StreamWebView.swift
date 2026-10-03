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
    var resumePosition: Double = 0
    var onNewLoad: (() -> Void)?
    var onNativeStreamFound: ((URL, [HTTPCookie]) -> Void)?
    var onProgress: ((Double, Double, Bool) -> Void)?

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let controller = WKUserContentController()
        controller.add(WeakScriptMessageHandler(context.coordinator), name: "vixMedia")
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.bounces = false
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        context.coordinator.update(resumePosition: resumePosition, onNativeStreamFound: onNativeStreamFound, onProgress: onProgress)
        context.coordinator.load(url, into: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(resumePosition: resumePosition, onNativeStreamFound: onNativeStreamFound, onProgress: onProgress)
        guard context.coordinator.currentURL != url else { return }
        context.coordinator.load(url, into: webView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onNewLoad: onNewLoad) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        private(set) var currentURL: URL?
        private var allowedHost: String?
        private weak var webView: WKWebView?
        let onNewLoad: (() -> Void)?
        private var resumePosition: Double = 0
        private var onNativeStreamFound: ((URL, [HTTPCookie]) -> Void)?
        private var onProgress: ((Double, Double, Bool) -> Void)?

        init(onNewLoad: (() -> Void)?) {
            self.onNewLoad = onNewLoad
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(receiveRemoteCommand(_:)),
                name: .velaWebRemoteCommand,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self, name: .velaWebRemoteCommand, object: nil)
        }

        @objc private func receiveRemoteCommand(_ notification: Notification) {
            performRemoteCommand(
                notification.userInfo?["action"] as? String,
                position: notification.userInfo?["position"] as? Double
            )
        }

        func update(resumePosition: Double, onNativeStreamFound: ((URL, [HTTPCookie]) -> Void)?, onProgress: ((Double, Double, Bool) -> Void)?) {
            self.resumePosition = resumePosition
            self.onNativeStreamFound = onNativeStreamFound
            self.onProgress = onProgress
        }

        func load(_ url: URL, into webView: WKWebView) {
            self.webView = webView
            currentURL = url
            allowedHost = url.host
            onNewLoad?()
            let controller = webView.configuration.userContentController
            controller.removeAllUserScripts()
            controller.addUserScript(WKUserScript(
                source: StreamWebView.mediaProbeScript(resumePosition: resumePosition),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
            webView.load(URLRequest(url: url))
        }

        private func performRemoteCommand(_ action: String?, position: Double?) {
            let operation: String
            switch action {
            case "play": operation = "video.play().catch(()=>{})"
            case "pause": operation = "video.pause()"
            case "seek":
                guard let position, position.isFinite else { return }
                operation = "video.currentTime=\(position)"
            default: return
            }
            let script = """
            (() => {
              const visit = frame => {
                try {
                  frame.document.querySelectorAll('video').forEach(video => { try { \(operation); } catch (_) {} });
                  for (let i = 0; i < frame.frames.length; i++) visit(frame.frames[i]);
                } catch (_) {}
              };
              visit(window);
            })();
            """
            webView?.evaluateJavaScript(script)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let kind = body["kind"] as? String else { return }
            if kind == "stream", let rawURL = body["url"] as? String,
               let url = URL(string: rawURL), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                let handler = onNativeStreamFound
                if let webView = message.frameInfo.webView {
                    webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                        handler?(url, cookies)
                    }
                } else {
                    handler?(url, [])
                }
            } else if kind == "progress",
                      let position = body["position"] as? Double,
                      let duration = body["duration"] as? Double,
                      let isPlaying = body["isPlaying"] as? Bool,
                      position.isFinite, duration.isFinite, duration > 0 {
                onProgress?(position, duration, isPlaying)
            }
        }

        /// Blocks redirect/hijack attempts within the same frame. Only the
        /// originally-loaded host (the chosen streaming server) and TMDB
        /// domains are allowed; everything else — ad redirects, affiliate
        /// hops, pop-under targets — is cancelled outright.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
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
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @Sendable () -> Void) {
            completionHandler()
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @Sendable (Bool) -> Void) {
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

    private static func mediaProbeScript(resumePosition: Double) -> String {
      return #"""
    (() => {
      if (window.__vixProbeInstalled) return;
      window.__vixProbeInstalled = true;
      window.__vixResumePosition = \#(max(0, resumePosition));
      const sent = new Set();
      const reportURL = (value, key = '') => {
        if (window.__vixNativeStreamSent) return;
        if (typeof value !== 'string') return;
        let candidate = value;
        try { candidate = decodeURIComponent(candidate); } catch (_) {}
        if (!/^https?:\/\//i.test(candidate)) return;
        if (!/(\.m3u8|\.mp4|\.mpd|\.webm)(?:[?#]|$)|\/(master|playlist|manifest)\b/i.test(candidate)) return;
        if (sent.has(candidate)) return;
        sent.add(candidate);
        window.__vixNativeStreamSent = true;
        window.webkit?.messageHandlers?.vixMedia?.postMessage({kind: 'stream', url: candidate});
      };
      const scan = (value, key = '', depth = 0) => {
        if (depth > 8 || value == null) return;
        if (typeof value === 'string') { if (/url|file|src|playlist|manifest|source/i.test(key)) reportURL(value, key); return; }
        if (Array.isArray(value)) { value.forEach(item => scan(item, key, depth + 1)); return; }
        if (typeof value === 'object') Object.keys(value).forEach(name => scan(value[name], name, depth + 1));
      };
      const scanText = text => {
        try { scan(JSON.parse(text)); } catch (_) {
          const matches = String(text).match(/https?:[^\s"'<>\\]+/gi) || [];
          matches.forEach(url => reportURL(url));
        }
      };
      const originalFetch = window.fetch;
      if (originalFetch) window.fetch = function(...args) {
        return originalFetch.apply(this, args).then(response => {
          try {
            const type = response.headers.get('content-type') || '';
            const url = response.url || '';
            const length = Number(response.headers.get('content-length') || 0);
            if ((/json|mpegurl|x-mpegurl/i.test(type) || /\/api\/|manifest/i.test(url)) && (!length || length < 2000000)) {
              response.clone().text().then(scanText).catch(() => {});
            }
          } catch (_) {}
          return response;
        });
      };
      const originalOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(...args) {
        this.addEventListener('load', () => {
          try {
            const type = this.getResponseHeader('content-type') || '';
            if (!(/json|mpegurl|x-mpegurl/i.test(type) || /\/api\/|manifest/i.test(this.responseURL || ''))) return;
            if (this.responseType === 'json') scan(this.response);
            else scanText(this.responseText);
          } catch (_) {}
        });
        return originalOpen.apply(this, args);
      };
      const probe = (forceProgress = false) => {
        try {
          document.querySelectorAll('video').forEach(video => {
            reportURL(video.currentSrc || video.src || '');
            const resume = Number(window.__vixResumePosition || 0);
            if (resume > 0 && video.readyState > 0 && video.currentTime < 1) {
              try { video.currentTime = Math.min(resume, Math.max(0, video.duration - 1)); } catch (_) {}
              window.__vixResumePosition = 0;
            }
            const position = Number.isFinite(video.currentTime) ? video.currentTime : 0;
            const duration = Number.isFinite(video.duration) ? video.duration : 0;
            if (duration > 0 && (forceProgress || Date.now() - Number(window.__vixLastProgressReport || 0) >= 3000)) {
              window.webkit?.messageHandlers?.vixMedia?.postMessage({kind:'progress', position, duration, isPlaying: !video.paused && !video.ended});
              window.__vixLastProgressReport = Date.now();
            }
          });
          performance.getEntriesByType('resource').slice(-80).forEach(entry => reportURL(entry.name));
          const jw = window.jwplayer;
          if (typeof jw === 'function') {
            const player = jw();
            const item = player && player.getPlaylistItem && player.getPlaylistItem();
            if (item) { reportURL(item.file || ''); (item.sources || []).forEach(source => reportURL(source.file || source.src || '')); }
          }
        } catch (_) {}
      };
      setInterval(probe, 1200);
      window.addEventListener('pagehide', () => probe(true));
    })();
    """#
    }

    private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
        weak var delegate: WKScriptMessageHandler?

        init(_ delegate: WKScriptMessageHandler) {
            self.delegate = delegate
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            delegate?.userContentController(userContentController, didReceive: message)
        }
    }
}
