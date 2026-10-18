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
    @State private var viewModel: CatalogViewModel?
    @State private var searchText = ""
    @State private var isSearchActive = false
    /// Separately tracked overlay visibility so we can animate it in/out
    /// with an explicit transaction. The .searchable binding is updated by
    /// UIKit's cancel button outside any SwiftUI animation context, so
    /// relying on .animation(value: isSearchActive) for the removal produces
    /// a snap. This state is always set inside withAnimation, giving us
    /// full control over both the fade-in and the fade-out.
    @State private var showSearchOverlay = false

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
            viewModel?.debounceSearch(newValue)
            // Show overlay when search is active and field is empty.
            // Animated separately so we control both directions.
            let shouldShow = isSearchActive && newValue.trimmingCharacters(in: .whitespaces).isEmpty
            if shouldShow != showSearchOverlay {
                withAnimation(.easeInOut(duration: 0.22)) { showSearchOverlay = shouldShow }
            }
        }
        .onChange(of: isSearchActive) { _, active in
            let shouldShow = active && searchText.trimmingCharacters(in: .whitespaces).isEmpty
            withAnimation(.easeInOut(duration: 0.22)) { showSearchOverlay = shouldShow }
        }
        .onSubmit(of: .search) {
            // Dismiss keyboard without opening the first result
            isSearchActive = false
        }
        .task {
            if viewModel == nil {
                viewModel = CatalogViewModel(store: store)
            }
            // Only load if we haven't loaded yet — prevents the flash of
            // the loading spinner every time the user switches back to Home.
            if viewModel?.homeLoaded == false {
                await viewModel?.loadHome()
            }
        }
        // Settings now lives in its own tab rather than a sheet presented
        // from Home, so Home can no longer trigger a reload right after
        // the credential is saved. Watch the store directly instead: any
        // tab that edits `store.credential` (currently only Settings)
        // causes Home to refetch automatically.
        .onChange(of: store.credential) { _, _ in
            Task { await viewModel?.loadHome() }
        }
        // Joined a watch party from a link: open what it's watching.
        .onReceive(NotificationCenter.default.publisher(for: .velaPartyOpen)) { notification in
            guard let media = notification.object as? PartyMedia, media.kind == "tmdb", let viewModel else { return }
            router.selection = .home
            PartySession.shared.attach(viewModel)
            Task { await viewModel.loadPartyMedia(media) }
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
            withAnimation(.easeInOut(duration: 0.22)) {
                searchText = ""
                isSearchActive = false
                showSearchOverlay = false
            }
            viewModel?.debounceSearch("")
        }
    }

    @ViewBuilder
    private func content(viewModel: CatalogViewModel) -> some View {
        ZStack {
            portraitContent(viewModel: viewModel)

            // Search overlay: shown when the bar is active with no text yet.
            // Driven by showSearchOverlay which is always set inside
            // withAnimation — guarantees the fade runs on both open and close,
            // even when the cancel button dismisses via UIKit.
            if showSearchOverlay {
                searchIdleOverlay(viewModel: viewModel)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func searchIdleOverlay(viewModel: CatalogViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.searchHistory.isEmpty {
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
                // Native List with swipe-to-delete — exactly what App Store uses.
                // List gives us free row separators, swipe actions, and correct
                // insets automatically. No custom VStack needed.
                List {
                    Section {
                        ForEach(store.searchHistory, id: \.self) { query in
                            Button {
                                searchText = query
                                viewModel.debounceSearch(query)
                            } label: {
                                Label(query, systemImage: "clock.arrow.circlepath")
                                    .foregroundStyle(.primary)
                            }
                            // Native swipe-to-delete — Apple's standard gesture
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    store.searchHistory.removeAll { $0 == query }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .onDelete { offsets in
                            store.searchHistory.remove(atOffsets: offsets)
                        }
                    } header: {
                        HStack {
                            Text("Recent Searches")
                            Spacer()
                            Button("Clear All") {
                                store.clearSearchHistory()
                            }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.blue)
                            .textCase(nil)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }

    @ViewBuilder
    private func portraitContent(viewModel: CatalogViewModel) -> some View {
        // Combine hero id + last-watched id into a single value so one
        // animation context drives all card transitions. Two competing
        // .animation(value:) modifiers on the same container fight each
        // other and produce choppiness — one is always enough.
        let animationAnchor = (viewModel.hero?.id ?? "") + (store.homeRecents.first?.id ?? "")

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Hero card — HeroView owns its own internal cross-fade.
                    HeroView(
                        item: viewModel.hero,
                        hasCredential: !store.credential.trimmingCharacters(in: .whitespaces).isEmpty,
                        onPlay: { Task { if let hero = viewModel.hero { await viewModel.open(hero) } } },
                        onSetup: { router.selection = .settings },
                        onToggleFavorite: { viewModel.toggleFavoriteOnHero() },
                        isFavorite: viewModel.hero.map(store.isFavorite) ?? false
                    )
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    // LastWatchedCard — only visible when the most-recent item
                    // is not already the hero. When tapped, open() sets hero to
                    // that item, flipping this condition to false and removing
                    // the card. The VStack (not LazyVStack) fully tracks the
                    // height change so the collapse is smooth.
                    if let lastWatched = store.homeRecents.first,
                       lastWatched.id != viewModel.hero?.id {
                        LastWatchedCard(
                            item: lastWatched,
                            isFavorite: store.isFavorite(lastWatched),
                            watchProgress: store.progress(for: lastWatched),
                            onContinue: {
                                Task { await viewModel.open(lastWatched) }
                            },
                            onFavorite: { store.toggleFavorite(lastWatched) }
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        // Apple-style card dismissal: fade + slight shrink.
                        // .move(edge: .top) in an unclipped container causes
                        // the card to visibly overlap the hero above it during
                        // removal — looks broken. Opacity + scale is what
                        // Apple Music and Apple TV use for card dismissal.
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
                                removal:  .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                            )
                        )
                    }

                    FilterBar(selected: filterBinding(viewModel: viewModel))
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                }

                // Rows sit in a LazyVStack inside the outer VStack so they
                // still lazy-load but the animated top section is fully tracked.
                LazyVStack(alignment: .leading, spacing: 28) {
                    statusOrRows(viewModel: viewModel)
                }
                .padding(.top, 16)
            }
            .padding(.bottom, 40)
            .padding(.top, 12)
            // Single animation context. iOS spring with a slightly longer
            // response (0.5) matches Apple's "standard" interactive spring
            // used throughout SpringBoard, Springboard, and SwiftUI sheets.
            .animation(.spring(response: 0.5, dampingFraction: 0.82),
                       value: animationAnchor)
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
