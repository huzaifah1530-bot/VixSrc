import SwiftUI

/// App entry point. Mirrors `main.js` app lifecycle concerns that are
/// relevant on iOS:
///   - `createWindow()` / `loadFile('index.html')`      -> RootView
///   - `loading.html` shown briefly before the real UI    -> LaunchView
///   - `vela://<id>` deep link / second-instance handoff -> onOpenURL
///     below, which is the iOS equivalent of Electron's custom protocol
///     registration (`app.setAsDefaultProtocolClient`) combined with
///     `open-url` / `second-instance`.
///
/// Auto-update via GitHub raw files (main.js's UPDATE_MANIFEST_URL /
/// UPDATE_EXE_BASE_URL flow, which swaps the running portable .exe) has no
/// iOS equivalent — the App Store (or TestFlight) owns app updates on iOS,
/// so that mechanism is intentionally NOT ported.
@main
struct VelaApp: App {
    @State private var store = AppStore()
    @State private var router = TabRouter()
    /// True only on cold start — the very first time this process renders.
    /// Set to false after the fade completes and never set back to true,
    /// so returning from background (warm resume from RAM) shows nothing.
    @State private var isLaunching = !VelaApp.hasLaunchedThisProcess

    /// Process-lifetime flag. False on cold start (first access), true
    /// for every subsequent scene activation within the same process.
    private static var hasLaunchedThisProcess: Bool = {
        // This runs once when the type is first accessed — i.e. at cold
        // start. We flip it to true immediately so any subsequent read
        // (background → foreground) sees true and skips the splash.
        let already = _hasLaunched
        _hasLaunched = true
        return already
    }()
    private static var _hasLaunched = false

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
                guard isLaunching else { return }
                // Wait for the first render pass to settle, then fade out
                // the splash. 400ms total feels instant on fast devices
                // while still giving slow devices time to draw the UI.
                try? await Task.sleep(nanoseconds: 400_000_000)
                withAnimation(.easeOut(duration: 0.35)) {
                    isLaunching = false
                }
            }
            .onOpenURL { url in
                handleDeepLink(url)
            }
        }
    }

    /// Accepts `vela://<id>` or `vela://open/<id>`, matching
    /// `extractTmdbId()` in main.js (`/^vixscr:\/\/(?:open\/)?(\d+)/i`).
    ///
    /// Note the host must be validated as numeric: for `vela://open/1726`
    /// `url.host` is `"open"`, not the id, so taking the host unconditionally
    /// would request `/movie/open` and 404.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "vela" else { return }

        let candidates = [url.host].compactMap { $0 } + url.pathComponents
        guard let id = candidates.first(where: { component in
            !component.isEmpty && component.allSatisfy(\.isNumber)
        }) else { return }

        router.selection = .home
        NotificationCenter.default.post(name: .velaOpenTMDBId, object: id)
    }
}

extension Notification.Name {
    static let velaOpenTMDBId = Notification.Name("vela.openTMDBId")
}

/// Native `TabView` root — Home / Favourites / Settings — instead of a
/// single scrolling screen with a hand-rolled pill nav bar. `TabView` gets
/// the real system tab bar for free: the iOS 26 Liquid Glass floating bar
/// on capable OS/device combinations, and the standard opaque/blurred bar
/// on iOS 17-25, with no extra drawing code from us either way.
struct RootView: View {
    @Environment(TabRouter.self) private var router
    @Environment(\.glassFidelity) private var glassFidelity

    var body: some View {
        @Bindable var router = router
        let tabs: some View = Group {
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

        return tabs
            // Apply UIKit appearance overrides so the system nav bar and tab
            // bar chrome respects Performance Mode. SwiftUI's .toolbarBackground
            // only controls the content fill — it cannot remove the floating
            // Liquid Glass shell that iOS 26 draws around NavigationStack chrome.
            // UINavigationBarAppearance.configureWithOpaqueBackground() is the
            // only API that forces the bar back to a flat, opaque surface on
            // iOS 26, same as it does on iOS 17-25.
            .onChange(of: glassFidelity, initial: true) { _, fidelity in
                applyBarAppearance(fidelity: fidelity)
            }
    }

    private func applyBarAppearance(fidelity: GlassFidelity) {
        let navAppearance = UINavigationBarAppearance()
        let tabAppearance = UITabBarAppearance()

        switch fidelity {
        case .full:
            // Let the system decide — on iOS 26 this gives Liquid Glass,
            // on iOS 17-25 it gives the standard blurred bar.
            navAppearance.configureWithDefaultBackground()
            tabAppearance.configureWithDefaultBackground()

        case .flat:
            // Opaque dark bar — matches the flat/translucent glass fallback
            // used by every other surface in the app under Performance Mode.
            navAppearance.configureWithOpaqueBackground()
            navAppearance.backgroundColor = UIColor(white: 0.06, alpha: 1)
            navAppearance.shadowColor = UIColor(white: 1, alpha: 0.08)
            navAppearance.titleTextAttributes = [.foregroundColor: UIColor.white]
            navAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
            tabAppearance.configureWithOpaqueBackground()
            tabAppearance.backgroundColor = UIColor(white: 0.06, alpha: 1)

        case .opaque:
            // Fully opaque black bar — matches Ultra Performance Mode
            // where even gradients and backdrop images are stripped.
            navAppearance.configureWithOpaqueBackground()
            navAppearance.backgroundColor = .black
            navAppearance.shadowColor = UIColor(white: 1, alpha: 0.12)
            navAppearance.titleTextAttributes = [.foregroundColor: UIColor.white]
            navAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
            tabAppearance.configureWithOpaqueBackground()
            tabAppearance.backgroundColor = .black
        }

        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance
    }
}
