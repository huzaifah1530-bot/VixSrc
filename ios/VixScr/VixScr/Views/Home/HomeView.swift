import Combine
import SwiftUI

/// Top-level Home tab. Uses native `NavigationStack` chrome — a large
/// collapsing title and `.searchable()` — instead of the previous
/// hand-built pill-shaped nav bar, so this reads as a normal iOS app
/// (Apple TV, Music, App Store, etc. all use exactly this pattern) rather
/// than a ported web page.
struct HomeView: View {
    @Environment(AppStore.self) private var store
    @Environment(TabRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.verticalSizeClass) private var vSizeClass
    @State private var viewModel: CatalogViewModel?
    @State private var searchText = ""
    @State private var isSearchActive = false

    /// iPhone landscape: both size classes are compact.
    private var isLandscape: Bool { hSizeClass == .compact && vSizeClass == .compact }

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    content(viewModel: viewModel)
                }
            }
            .background(VixTheme.background.ignoresSafeArea())
            .navigationTitle("Vela")
            .navigationBarTitleDisplayMode(.large)
        }
        .searchable(text: $searchText, isPresented: $isSearchActive, prompt: "Movies, TV shows...")
        .onChange(of: searchText) { _, newValue in
            viewModel?.previewHero(fromQueryPreview: newValue)
            viewModel?.debounceSearch(newValue)
        }
        .onSubmit(of: .search) {
            // Dismiss keyboard without opening the first result
            isSearchActive = false
        }
        .task {
            if viewModel == nil {
                viewModel = CatalogViewModel(store: store)
            }
            await viewModel?.loadHome()
        }
        // Settings now lives in its own tab rather than a sheet presented
        // from Home, so Home can no longer trigger a reload right after
        // the credential is saved. Watch the store directly instead: any
        // tab that edits `store.credential` (currently only Settings)
        // causes Home to refetch automatically.
        .onChange(of: store.credential) { _, _ in
            Task { await viewModel?.loadHome() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .velaOpenTMDBId)) { notification in
            guard let id = notification.object as? String else { return }
            router.selection = .home
            Task { await viewModel?.openByTMDBId(id) }
        }
        // Apple pattern: tapping the active tab's icon clears search and
        // returns to the home feed — same behaviour as App Store, Music, etc.
        .onReceive(NotificationCenter.default.publisher(for: .velaClearSearch)) { _ in
            guard router.selection == .home else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                searchText = ""
                isSearchActive = false
            }
            viewModel?.debounceSearch("")
        }
    }

    @ViewBuilder
    private func content(viewModel: CatalogViewModel) -> some View {
        ZStack {
            if isLandscape {
                landscapeContent(viewModel: viewModel)
            } else {
                portraitContent(viewModel: viewModel)
            }

            // Search overlay: shown when search bar is active but no text
            // typed yet. Black background + recent searches, App Store style.
            if isSearchActive && searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                searchIdleOverlay(viewModel: viewModel)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: isSearchActive)
    }

    /// Full-screen search idle state — shown immediately when the search bar
    /// is tapped, before the user types. Black background, recent searches
    /// as a grouped list with section header and clear button, matching the
    /// App Store's search focus state.
    @ViewBuilder
    private func searchIdleOverlay(viewModel: CatalogViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.searchHistory.isEmpty {
                // Nothing to show yet
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("Search Movies & TV")
                        .font(.title3.weight(.semibold))
                    Text("Start typing to find something to watch.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Section header — matches App Store "Recent" style
                        HStack {
                            Text("Recent")
                                .font(.title3.weight(.bold))
                            Spacer()
                            Button("Clear") {
                                store.clearSearchHistory()
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.blue)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 12)

                        // Grouped rounded rect card, like App Store recent searches
                        VStack(spacing: 0) {
                            ForEach(Array(store.searchHistory.enumerated()), id: \.offset) { idx, query in
                                Button {
                                    searchText = query
                                    viewModel.debounceSearch(query)
                                } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .font(.system(size: 15))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 20)

                                        Text(query)
                                            .font(.body)
                                            .foregroundStyle(.primary)

                                        Spacer()

                                        Image(systemName: "arrow.up.left")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 13)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if idx < store.searchHistory.count - 1 {
                                    Divider()
                                        .padding(.leading, 50)
                                }
                            }
                        }
                        .background(Color.white.opacity(0.07),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        )
                        .padding(.horizontal, 20)
                    }
                    .padding(.bottom, 40)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }

    // MARK: - Portrait layout (unchanged)

    @ViewBuilder
    private func portraitContent(viewModel: CatalogViewModel) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28, pinnedViews: []) {
                if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    HeroView(
                        item: viewModel.hero,
                        hasCredential: !store.credential.trimmingCharacters(in: .whitespaces).isEmpty,
                        onPlay: { Task { if let hero = viewModel.hero { await viewModel.open(hero) } } },
                        onSetup: { router.selection = .settings },
                        onToggleFavorite: { viewModel.toggleFavoriteOnHero() },
                        isFavorite: viewModel.hero.map(store.isFavorite) ?? false
                    )
                    .containerRelativeFrame(.horizontal) { width, _ in width - 40 }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .id(viewModel.hero?.id)
                    .transition(.opacity)

                    if let lastWatched = store.sortedRecents.first,
                       lastWatched.id != viewModel.hero?.id {
                        LastWatchedCard(
                            item: lastWatched,
                            isFavorite: store.isFavorite(lastWatched),
                            onContinue: { Task { await viewModel.open(lastWatched) } },
                            onFavorite: { store.toggleFavorite(lastWatched) }
                        )
                        .containerRelativeFrame(.horizontal) { width, _ in width - 40 }
                        .padding(.horizontal, 20)
                    }

                    FilterBar(selected: filterBinding(viewModel: viewModel))
                        .padding(.horizontal, 20)
                }
                statusOrRows(viewModel: viewModel)
            }
            .padding(.bottom, 40)
            .padding(.top, 12)
        }
        .overlay(alignment: .bottom) {
            if let toast = viewModel.toastMessage {
                ToastView(message: toast)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel.isPlayerPresented },
            set: { viewModel.isPlayerPresented = $0 }
        )) {
            PlayerSheet(viewModel: viewModel)
        }
    }

    // MARK: - Landscape layout
    // Left: hero + last watched stacked (fixed ~45% width)
    // Right: filter bar + rows scrolling vertically

    @ViewBuilder
    private func landscapeContent(viewModel: CatalogViewModel) -> some View {
        GeometryReader { geo in
            let leftWidth = geo.size.width * 0.42
            let rightWidth = geo.size.width - leftWidth

            HStack(alignment: .top, spacing: 0) {
                // LEFT — hero panel, fixed width, scrolls independently
                ScrollView {
                    VStack(spacing: 12) {
                        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                            HeroView(
                                item: viewModel.hero,
                                hasCredential: !store.credential.trimmingCharacters(in: .whitespaces).isEmpty,
                                onPlay: { Task { if let hero = viewModel.hero { await viewModel.open(hero) } } },
                                onSetup: { router.selection = .settings },
                                onToggleFavorite: { viewModel.toggleFavoriteOnHero() },
                                isFavorite: viewModel.hero.map(store.isFavorite) ?? false
                            )
                            .id(viewModel.hero?.id)
                            .transition(.opacity)

                            if let lastWatched = store.sortedRecents.first,
                               lastWatched.id != viewModel.hero?.id {
                                LastWatchedCard(
                                    item: lastWatched,
                                    isFavorite: store.isFavorite(lastWatched),
                                    onContinue: { Task { await viewModel.open(lastWatched) } },
                                    onFavorite: { store.toggleFavorite(lastWatched) }
                                )
                            }
                        }
                    }
                    .padding(12)
                    .padding(.bottom, 20)
                }
                .frame(width: leftWidth)

                Divider()
                    .background(Color.white.opacity(0.1))

                // RIGHT — filter + rows
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                            FilterBar(selected: filterBinding(viewModel: viewModel))
                                .padding(.horizontal, 16)
                        }
                        statusOrRows(viewModel: viewModel)
                    }
                    .padding(.bottom, 30)
                    .padding(.top, 8)
                }
                .frame(width: rightWidth)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = viewModel.toastMessage {
                ToastView(message: toast)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel.isPlayerPresented },
            set: { viewModel.isPlayerPresented = $0 }
        )) {
            PlayerSheet(viewModel: viewModel)
        }
    }

    @ViewBuilder
    private func statusOrRows(viewModel: CatalogViewModel) -> some View {
        if viewModel.isLoadingHome {
            HStack {
                Spacer()
                ProgressView("Loading from TMDB")
                    .tint(.white)
                    .padding(.top, 60)
                Spacer()
            }
        } else if let error = viewModel.homeErrorMessage {
            statusCard(
                systemImage: "exclamationmark.triangle.fill",
                title: "TMDB request failed",
                message: error,
                actionTitle: "Check API Key"
            ) { router.selection = .settings }
        } else if store.credential.trimmingCharacters(in: .whitespaces).isEmpty {
            statusCard(
                systemImage: "key.fill",
                title: "Add a TMDB key first",
                message: "Add your TMDB API key or read access token in Settings to browse the live catalogue.",
                actionTitle: "Open Settings"
            ) { router.selection = .settings }
        } else if viewModel.totalResultCount == 0 {
            if viewModel.isSearching {
                // Debounce is pending or request in flight — show a spinner
                // so the user sees standby feedback instead of "no results".
                HStack {
                    Spacer()
                    ProgressView()
                        .tint(.white)
                        .padding(.top, 60)
                    Spacer()
                }
            } else {
                statusCard(
                    systemImage: "magnifyingglass",
                    title: searchText.isEmpty ? "No matches found" : "No results for \u{201c}\(searchText)\u{201d}",
                    message: "Try another title. TMDB search starts after 2 characters.",
                    actionTitle: nil,
                    action: nil
                )
            }
        } else {
            ForEach(viewModel.displayedRows) { row in
                if row.title == "Search results" {
                    // Search: 2-column vertical grid matching the Favourites layout
                    SearchResultsGrid(items: row.items, store: store) { item in
                        Task { await viewModel.open(item) }
                    }
                } else if row.title == "Continue watching" {
                    ContinueWatchingRowView(
                        title: row.title,
                        subtitle: row.subtitle,
                        sourceItems: row.items,
                        store: store
                    ) { item in
                        Task { await viewModel.open(item) }
                    }
                } else {
                    MediaRowView(row: row, store: store) { item in
                        Task { await viewModel.open(item) }
                    }
                }
            }
        }
    }

    /// A native, reusable empty/error state. Mirrors `ContentUnavailableView`
    /// styling conventions (centered SF Symbol, title, description, and an
    /// optional bordered-prominent action button) while staying available
    /// back to iOS 17, where `ContentUnavailableView` itself already exists
    /// (iOS 17+) but its "Retry"-style action button layout doesn't quite
    /// match what we need here, so this stays hand-rolled with native
    /// components rather than the previous custom glass card.
    private func statusCard(
        systemImage: String,
        title: String,
        message: String,
        actionTitle: String?,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(28)
        .padding(.horizontal, 20)
        .padding(.top, 40)
    }

    private func filterBinding(viewModel: CatalogViewModel) -> Binding<AppStore.ContentFilter> {
        Binding(
            get: { store.contentFilter },
            set: { newValue in
                store.contentFilter = newValue
            }
        )
    }
}

struct ToastView: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .vixGlass(.strong, cornerRadius: 999)
            .shadow(radius: 12)
    }
}
