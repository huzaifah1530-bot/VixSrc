import Combine
import SwiftUI

/// Top-level screen. Mirrors the `<header>` + `#hero` + `#workspace`
/// structure in index.html: nav bar with search, hero banner, filter chips,
/// and the stack of media rows.
struct HomeView: View {
    @Environment(AppStore.self) private var store
    @State private var viewModel: CatalogViewModel?
    @State private var searchText = ""
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                VixTheme.background.ignoresSafeArea()

                if let viewModel {
                    content(viewModel: viewModel)
                }
            }
            .toolbar(.hidden)
        }
        .task {
            if viewModel == nil {
                viewModel = CatalogViewModel(store: store)
            }
            await viewModel?.loadHome()
        }
        .onReceive(NotificationCenter.default.publisher(for: .vixscrOpenTMDBId)) { notification in
            guard let id = notification.object as? String else { return }
            Task { await viewModel?.openByTMDBId(id) }
        }
    }

    @ViewBuilder
    private func content(viewModel: CatalogViewModel) -> some View {
        ScrollView {
            VStack(spacing: 28) {
                HeroView(
                    item: viewModel.hero,
                    hasCredential: !store.credential.trimmingCharacters(in: .whitespaces).isEmpty,
                    onPlay: { Task { if let hero = viewModel.hero { await viewModel.open(hero) } } },
                    onSetup: { viewModel.isSettingsPresented = true },
                    onBrowse: {},
                    onToggleFavorite: { viewModel.toggleFavoriteOnHero() },
                    isFavorite: viewModel.hero.map(store.isFavorite) ?? false
                )
                .clipShape(RoundedRectangle(cornerRadius: 0))

                FilterBar(selected: filterBinding(viewModel: viewModel))
                    .padding(.horizontal, 20)

                if viewModel.isLoadingHome {
                    ProgressView("Loading from TMDB")
                        .tint(.white)
                        .foregroundStyle(.white)
                        .padding(.top, 60)
                } else if let error = viewModel.homeErrorMessage {
                    errorCard(message: error, viewModel: viewModel)
                } else if store.credential.trimmingCharacters(in: .whitespaces).isEmpty {
                    setupCard(viewModel: viewModel)
                } else if viewModel.totalResultCount == 0 {
                    emptyCard
                } else {
                    ForEach(viewModel.displayedRows) { row in
                        MediaRowView(row: row, store: store) { item in
                            Task { await viewModel.open(item) }
                        }
                    }
                }
            }
            .padding(.bottom, 40)
        }
        .safeAreaInset(edge: .top) {
            navBar(viewModel: viewModel)
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
        .sheet(isPresented: Binding(
            get: { viewModel.isSettingsPresented },
            set: { viewModel.isSettingsPresented = $0 }
        )) {
            SettingsSheet(viewModel: viewModel)
        }
    }

    private func filterBinding(viewModel: CatalogViewModel) -> Binding<AppStore.ContentFilter> {
        Binding(
            get: { store.contentFilter },
            set: { newValue in
                store.contentFilter = newValue
            }
        )
    }

    @ViewBuilder
    private func navBar(viewModel: CatalogViewModel) -> some View {
        VStack(spacing: 10) {
            // Grouped so the three nav-bar glass surfaces morph/merge together
            // on iOS 26 instead of rendering as three unrelated panes.
            VixGlassContainer {
            // Unlike a plain HStack of three independently-sized pills (which
            // could overflow on narrower widths or larger Dynamic Type, the
            // same bug already fixed in HeroView's button row), the brand
            // pill and settings button are fixed-size while the search pill
            // is the only flexible element and absorbs all the shrinking.
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(.white)
                        Image(systemName: "play.fill").foregroundStyle(.black).font(.system(size: 12, weight: .bold))
                    }
                    .frame(width: 32, height: 32)
                    Text("Screen House")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .vixGlass(.regular, cornerRadius: 999)
                .layoutPriority(1)
                .fixedSize()

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.55))
                    TextField("", text: $searchText, prompt: Text("Search...").foregroundStyle(.white.opacity(0.42)))
                        .foregroundStyle(.white)
                        .focused($searchFieldFocused)
                        .lineLimit(1)
                        .onChange(of: searchText) { _, newValue in
                            viewModel.previewHero(fromQueryPreview: newValue)
                            viewModel.debounceSearch(newValue)
                        }
                        .onSubmit {
                            Task { await viewModel.commitSearch(openBest: true) }
                        }
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            Task { await viewModel.runSearch("") }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white.opacity(0.5))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .vixGlass(.regular, cornerRadius: 999)
                // The only element allowed to shrink, so the row as a whole
                // never exceeds the available width.
                .layoutPriority(0)

                Button { viewModel.isSettingsPresented = true } label: {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.white)
                        // 44x44 is Apple's documented minimum tap target
                        // (was 40x40).
                        .frame(width: 44, height: 44)
                }
                .vixGlass(.regular, cornerRadius: 999)
                .accessibilityLabel("Settings")
                .layoutPriority(1)
                .fixedSize()
            }
            }

            if searchFieldFocused || !searchText.isEmpty {
                SearchOverlay(
                    query: searchText,
                    items: viewModel.searchItems,
                    recentSearches: store.searchHistory,
                    statusText: searchText.isEmpty ? "Recent searches" : "Live TMDB results",
                    onSelectRecent: { query in
                        searchText = query
                        Task {
                            await viewModel.runSearch(query)
                        }
                    },
                    onSelectItem: { item in
                        store.addSearchHistory(searchText.isEmpty ? item.title : searchText)
                        searchFieldFocused = false
                        Task { await viewModel.open(item) }
                    },
                    onClearRecents: { store.clearSearchHistory() }
                )
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.black.opacity(0.001)) // keeps hit-testing across the safe area inset
    }

    private func errorCard(message: String, viewModel: CatalogViewModel) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 28)).foregroundStyle(.white.opacity(0.8))
            Text("TMDB request failed").font(.system(size: 22, weight: .black)).foregroundStyle(.white)
            Text(message).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.58)).multilineTextAlignment(.center)
            Button("Check API key") { viewModel.isSettingsPresented = true }
                .font(.system(size: 14, weight: .black))
                .padding(.horizontal, 20).padding(.vertical, 12)
                .foregroundStyle(.black)
                .background(.white, in: Capsule())
        }
        .padding(28)
        .vixGlass(.strong, cornerRadius: 32)
        .padding(.horizontal, 20)
        .padding(.top, 40)
    }

    private func setupCard(viewModel: CatalogViewModel) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "key.fill").font(.system(size: 28)).foregroundStyle(.white.opacity(0.8))
            Text("Add a TMDB key first").font(.system(size: 22, weight: .black)).foregroundStyle(.white)
            Text("Add your TMDB API key or read access token in Settings to browse the live catalogue.")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.58)).multilineTextAlignment(.center)
            Button("Open Settings") { viewModel.isSettingsPresented = true }
                .font(.system(size: 14, weight: .black))
                .padding(.horizontal, 20).padding(.vertical, 12)
                .foregroundStyle(.black)
                .background(.white, in: Capsule())
        }
        .padding(28)
        .vixGlass(.strong, cornerRadius: 32)
        .padding(.horizontal, 20)
        .padding(.top, 40)
    }

    // MARK: - Empty/error states

    private var emptyCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.magnifyingglass").font(.system(size: 28)).foregroundStyle(.white.opacity(0.75))
            Text("No matches found").font(.system(size: 22, weight: .black)).foregroundStyle(.white)
            Text("Try another title. TMDB search starts after 2 characters.")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.58))
        }
        .padding(28)
        .vixGlass(.strong, cornerRadius: 32)
        .padding(.horizontal, 20)
        .padding(.top, 40)
    }
}

struct ToastView: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.system(size: 14, weight: .black))
            .foregroundStyle(.black)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.white, in: Capsule())
            .shadow(radius: 12)
    }
}
