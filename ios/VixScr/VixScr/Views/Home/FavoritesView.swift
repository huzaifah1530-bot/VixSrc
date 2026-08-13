import SwiftUI

/// Favourites tab. Native adaptive grid (the same layout pattern Photos and
/// the App Store use for grids of cards) instead of a horizontal shelf,
/// since this is the one collection a user is likely to want to scan as a
/// whole rather than skim past.
struct FavoritesView: View {
    @Environment(AppStore.self) private var store
    @State private var viewModel: CatalogViewModel?
    @State private var scrollPosition: ScrollPosition = .init()

    private let columns = [GridItem(.adaptive(minimum: 124, maximum: 154), spacing: 14)]

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
                    .scrollPosition($scrollPosition)
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
