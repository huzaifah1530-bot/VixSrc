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
    @State private var router = TabRouter()
    @State private var isLaunching = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environment(store)
                    .environment(router)

                if isLaunching {
                    LaunchView()
                        .transition(.opacity)
                }
            }
            // Propagates Performance / Ultra Performance mode to every glass
            // surface, the iOS analogue of toggling `body.perf-mode` /
            // `body.ultra-perf-mode` in index.html.
            .vixGlassFidelity(
                performanceMode: store.performanceMode,
                ultraPerformanceMode: store.ultraPerformanceMode
            )
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
    /// `extractTmdbId()` in main.js (`/^vixscr:\/\/(?:open\/)?(\d+)/i`).
    ///
    /// Note the host must be validated as numeric: for `vixscr://open/1726`
    /// `url.host` is `"open"`, not the id, so taking the host unconditionally
    /// would request `/movie/open` and 404.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "vixscr" else { return }

        let candidates = [url.host].compactMap { $0 } + url.pathComponents
        guard let id = candidates.first(where: { component in
            !component.isEmpty && component.allSatisfy(\.isNumber)
        }) else { return }

        router.selection = .home
        NotificationCenter.default.post(name: .vixscrOpenTMDBId, object: id)
    }
}

extension Notification.Name {
    static let vixscrOpenTMDBId = Notification.Name("vixscr.openTMDBId")
}

/// Native `TabView` root — Home / Favourites / Settings — instead of a
/// single scrolling screen with a hand-rolled pill nav bar. `TabView` gets
/// the real system tab bar for free: the iOS 26 Liquid Glass floating bar
/// on capable OS/device combinations, and the standard opaque/blurred bar
/// on iOS 17-25, with no extra drawing code from us either way.
struct RootView: View {
    @Environment(TabRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        if #available(iOS 18.0, *) {
            // The `Tab(value:)` initialiser and `.sidebarAdaptable` style are
            // iOS 18+ only (the latter is what lets the bar collapse into a
            // sidebar on iPad and, on iOS 26, adopt the floating glass tab
            // bar treatment). Older OSes fall through to the classic
            // `.tag()`-based TabView below, which has worked since iOS 13.
            TabView(selection: $router.selection) {
                Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                    HomeView()
                }
                Tab("Favourites", systemImage: "heart.fill", value: AppTab.favorites) {
                    FavoritesView()
                }
                Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                    SettingsView()
                }
            }
            .tabViewStyle(.sidebarAdaptable)
        } else {
            TabView(selection: $router.selection) {
                HomeView()
                    .tabItem { Label("Home", systemImage: "house.fill") }
                    .tag(AppTab.home)
                FavoritesView()
                    .tabItem { Label("Favourites", systemImage: "heart.fill") }
                    .tag(AppTab.favorites)
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                    .tag(AppTab.settings)
            }
        }
    }
}
