import SwiftUI

/// Favourites tab. Native adaptive grid (the same layout pattern Photos and
/// the App Store use for grids of cards) instead of a horizontal shelf,
/// since this is the one collection a user is likely to want to scan as a
/// whole rather than skim past.
struct FavoritesView: View {
    @Environment(AppStore.self) private var store
    @Environment(TabRouter.self) private var router
    @Environment(AnimeViewModel.self) private var animeViewModel
    @State private var viewModel: CatalogViewModel?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 14)]
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.favorites.isEmpty {
                    ContentUnavailableView(
                        "No Favourites Yet",
                        systemImage: "heart",
                        description: Text("Titles you favourite from Home or the player will show up here.")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(store.favorites) { item in
                                GeometryReader { geometry in
                                    PosterCard(
                                        item: item,
                                        isFavorite: true,
                                        compact: store.cardSize == .compact,
                                        watchProgress: store.progress(for: item),
                                        widthOverride: geometry.size.width,
                                        canRemoveFromHistory: store.recents.contains { $0.id == item.id } || store.progress(for: item) != nil,
                                        onTap: { Task { await open(item) } },
                                        onToggleFavorite: { store.toggleFavorite(item) },
                                        onRemoveFromHistory: { store.removeFromHistory(item) }
                                    )
                                }
                                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .background(VixTheme.background.ignoresSafeArea())
            .navigationTitle("Favourites")
            .navigationBarTitleDisplayMode(.large)
        }
        .task {
            if viewModel == nil {
                viewModel = CatalogViewModel(store: store)
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel?.isPlayerPresented ?? false },
            set: { viewModel?.isPlayerPresented = $0 }
        )) {
            if let viewModel {
                PlayerSheet(viewModel: viewModel)
            }
        }
    }

    private func open(_ item: MediaItem) async {
        // Anime-tab titles play in the Anime tab's player.
        if item.isAnimeCatalog {
            guard store.animeEnabled else { return }
            router.selection = .anime
            animeViewModel.open(item)
            return
        }
        if viewModel == nil {
            viewModel = CatalogViewModel(store: store)
        }
        await viewModel?.open(item)
    }
}
