import SwiftUI

/// App entry point. Mirrors `main.js` app lifecycle concerns that are
/// relevant on iOS:
///   - `createWindow()` / `loadFile('index.html')`      -> RootView
///   - `loading.html` shown briefly before the real UI    -> LaunchView
///   - `vixscr://<id>` deep link / second-instance handoff -> onOpenURL
///     below, which is the iOS equivalent of Electron's custom protocol
///     registration (`app.setAsDefaultProtocolClient`) combined with
///     `open-url` / `second-instance`.
///
/// Auto-update via GitHub raw files (main.js's UPDATE_MANIFEST_URL /
/// UPDATE_EXE_BASE_URL flow, which swaps the running portable .exe) has no
/// iOS equivalent — the App Store (or TestFlight) owns app updates on iOS,
/// so that mechanism is intentionally NOT ported.
@main
struct VixScrApp: App {
    @State private var store = AppStore()
    @State private var isLaunching = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environment(store)

                if isLaunching {
                    LaunchView()
                        .transition(.opacity)
                }
            }
            .task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                withAnimation(.easeOut(duration: 0.25)) {
                    isLaunching = false
                }
            }
            .onOpenURL { url in
                handleDeepLink(url)
            }
        }
    }

    /// Accepts `vixscr://<id>` or `vixscr://open/<id>`, matching
    /// `extractTmdbId()` in main.js.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "vixscr" else { return }
        let id = url.host ?? url.pathComponents.last(where: { $0 != "/" && $0 != "open" })
        guard let id, !id.isEmpty else { return }
        NotificationCenter.default.post(name: .vixscrOpenTMDBId, object: id)
    }
}

extension Notification.Name {
    static let vixscrOpenTMDBId = Notification.Name("vixscr.openTMDBId")
}

struct RootView: View {
    var body: some View {
        HomeView()
    }
}
