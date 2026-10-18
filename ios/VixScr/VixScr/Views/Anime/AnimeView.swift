import SwiftUI

/// The Anime tab: Home's layout (hero, continue watching, shelves, search)
/// fed entirely by the anime site's own catalogue instead of TMDB.
struct AnimeView: View {
    @Environment(AppStore.self) private var store
    @Environment(TabRouter.self) private var router
    @Bindable var viewModel: AnimeViewModel
    @State private var searchText = ""
    @State private var isSearchActive = false
    @State private var showSearchOverlay = false

    var body: some View {
        NavigationStack {
            content
                .background(VixTheme.background.ignoresSafeArea())
                .navigationTitle("Anime")
                .navigationBarTitleDisplayMode(.large)
        }
        .searchable(text: $searchText, isPresented: $isSearchActive, prompt: "Search anime...")
        .onChange(of: searchText) { _, newValue in
            viewModel.debounceSearch(newValue)
            let shouldShow = isSearchActive && newValue.trimmingCharacters(in: .whitespaces).isEmpty
            if shouldShow != showSearchOverlay {
                withAnimation(.easeInOut(duration: 0.22)) { showSearchOverlay = shouldShow }
            }
        }
        .onChange(of: isSearchActive) { _, active in
            let shouldShow = active && searchText.trimmingCharacters(in: .whitespaces).isEmpty
            withAnimation(.easeInOut(duration: 0.22)) { showSearchOverlay = shouldShow }
        }
        .onSubmit(of: .search) { isSearchActive = false }
        .task {
            if !viewModel.homeLoaded { await viewModel.loadHome() }
        }
        // Reload if the catalogue server changes in Settings.
        .onChange(of: store.animeServers.first?.base) { _, _ in
            Task { await viewModel.loadHome() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .velaPartyOpen)) { notification in
            guard let media = notification.object as? PartyMedia, media.kind == "anime" else { return }
            guard store.animeEnabled else { PartySession.shared.show("Turn on Anime in Settings to join this party"); return }
            router.selection = .anime
            PartySession.shared.attach(viewModel)
            Task { await viewModel.loadPartyMedia(media) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .velaClearAnimeSearch)) { _ in
            withAnimation(.easeInOut(duration: 0.22)) {
                searchText = ""
                isSearchActive = false
                showSearchOverlay = false
            }
            viewModel.debounceSearch("")
        }
        .sheet(isPresented: $viewModel.isPlayerPresented, onDismiss: { viewModel.closePlayer() }) {
            AnimePlayerSheet(viewModel: viewModel)
        }
    }

    private var content: some View {
        ZStack {
            feed
            if showSearchOverlay {
                searchHistoryOverlay.transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = viewModel.toastMessage {
                ToastView(message: toast)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var feed: some View {
        let isSearching = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !isSearching, viewModel.hero != nil {
                    HeroView(
                        item: viewModel.hero,
                        hasCredential: true,
                        onPlay: { if let hero = viewModel.hero { viewModel.open(hero) } },
                        onSetup: {},
                        onToggleFavorite: { viewModel.toggleFavoriteOnHero() },
                        isFavorite: viewModel.hero.map(store.isFavorite) ?? false
                    )
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
                if !isSearching {
                    if let last = store.animeRecents.first, last.id != viewModel.hero?.id {
                        LastWatchedCard(
                            item: last,
                            isFavorite: store.isFavorite(last),
                            watchProgress: store.progress(for: last),
                            onContinue: { viewModel.open(last) },
                            onFavorite: { store.toggleFavorite(last) }
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    }
                }

                LazyVStack(alignment: .leading, spacing: 28) {
                    rows
                }
                .padding(.top, 20)
            }
            .padding(.bottom, 40)
            .padding(.top, 12)
            .animation(.spring(response: 0.5, dampingFraction: 0.82),
                       value: (viewModel.hero?.id ?? "") + (store.animeRecents.first?.id ?? ""))
        }
        .refreshable { await viewModel.loadHome() }
    }

    @ViewBuilder
    private var rows: some View {
        if store.animeServers.isEmpty {
            status(systemImage: "server.rack", title: "No anime servers",
                   message: "Add an anime server such as AnimeKai in Settings to browse anime.",
                   actionTitle: "Open Settings") { router.selection = .settings }
        } else if viewModel.isLoadingHome && viewModel.displayedRows.isEmpty {
            HStack { Spacer(); ProgressView("Loading anime").tint(.white).padding(.top, 60); Spacer() }
        } else if let error = viewModel.homeErrorMessage, viewModel.displayedRows.isEmpty {
            status(systemImage: "exclamationmark.triangle.fill", title: "Couldn't load anime",
                   message: error, actionTitle: "Try Again") { Task { await viewModel.loadHome() } }
        } else if !searchText.trimmingCharacters(in: .whitespaces).isEmpty && viewModel.searchItems.isEmpty {
            if viewModel.isSearching {
                HStack { Spacer(); ProgressView().tint(.white).padding(.top, 60); Spacer() }
            } else {
                status(systemImage: "magnifyingglass", title: "No results for \u{201c}\(searchText)\u{201d}",
                       message: "Try the English or Japanese title.", actionTitle: nil, action: nil)
            }
        } else {
            ForEach(viewModel.displayedRows) { row in
                if row.title == "Search results" {
                    SearchResultsGrid(items: row.items, store: store) { viewModel.open($0) }
                } else if row.title == "Continue watching" {
                    ContinueWatchingRowView(title: row.title, subtitle: row.subtitle, sourceItems: row.items, store: store) {
                        viewModel.open($0)
                    }
                } else {
                    MediaRowView(row: row, store: store) { viewModel.open($0) }
                }
            }
        }
    }

    private var searchHistoryOverlay: some View {
        Group {
            if store.animeSearchHistory.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("Search Anime")
                        .font(.title3.weight(.semibold))
                    Text("Find any series or movie by its English or Japanese title.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else {
                List {
                    Section {
                        ForEach(store.animeSearchHistory, id: \.self) { query in
                            Button {
                                searchText = query
                            } label: {
                                Label(query, systemImage: "clock.arrow.circlepath")
                                    .foregroundStyle(.primary)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    store.animeSearchHistory.removeAll { $0 == query }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("Recent Searches")
                            Spacer()
                            Button("Clear All") { store.animeSearchHistory = [] }
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

    private func status(systemImage: String, title: String, message: String,
                        actionTitle: String?, action: (() -> Void)?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
}
