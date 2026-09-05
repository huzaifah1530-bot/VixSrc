import SwiftUI

/// Favourites tab. Native adaptive grid (the same layout pattern Photos and
/// the App Store use for grids of cards) instead of a horizontal shelf,
/// since this is the one collection a user is likely to want to scan as a
/// whole rather than skim past.
struct FavoritesView: View {
    @Environment(AppStore.self) private var store
    @State private var viewModel: CatalogViewModel?

    private var columns: [GridItem] {
        return Array(repeating: GridItem(.flexible(), spacing: 14), count: 2)
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
                                PosterCard(
                                    item: item,
                                    isFavorite: true,
                                    compact: store.cardSize == .compact,
                                    onTap: { Task { await open(item) } }
                                )
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
        if viewModel == nil {
            viewModel = CatalogViewModel(store: store)
        }
        await viewModel?.open(item)
    }
}
