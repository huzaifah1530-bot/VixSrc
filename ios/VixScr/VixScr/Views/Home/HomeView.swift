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
        .searchSuggestions {
            if searchText.isEmpty {
                ForEach(store.searchHistory, id: \.self) { recent in
                    Label(recent, systemImage: "clock.arrow.circlepath")
                        .searchCompletion(recent)
                }
            }
        }
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
                    // Use the full scroll view width minus padding.
                    // containerRelativeFrame gives us the actual available width
                    // so the card never sizes to content — it always fills edge to edge.
                    .containerRelativeFrame(.horizontal) { width, _ in
                        width - 40 // 20pt padding each side
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

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
            statusCard(
                systemImage: "magnifyingglass",
                title: searchText.isEmpty ? "No matches found" : "No results for \u{201c}\(searchText)\u{201d}",
                message: "Try another title. TMDB search starts after 2 characters.",
                actionTitle: nil,
                action: nil
            )
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
