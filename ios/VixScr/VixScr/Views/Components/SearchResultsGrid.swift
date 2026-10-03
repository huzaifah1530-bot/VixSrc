import SwiftUI

/// 2-column vertical grid for search results — same layout as FavoritesView.
/// Cards fill the available width (padding 20 each side, 14pt gap between).
struct SearchResultsGrid: View {
    let items: [MediaItem]
    let store: AppStore
    let onSelect: (MediaItem) -> Void

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 14)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Search results")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Text("Live and fuzzy TMDB matches")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 20)

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(items) { item in
                    // Use a wider card so the two-column layout fills the screen
                    // with the same side padding (20pt) as every other row.
                    SearchPosterCard(
                        item: item,
                        isFavorite: store.isFavorite(item),
                        watchProgress: store.progress(for: item),
                        canRemoveFromHistory: store.recents.contains { $0.id == item.id } || store.progress(for: item) != nil,
                        onTap: { onSelect(item) },
                        onToggleFavorite: { store.toggleFavorite(item) },
                        onRemoveFromHistory: { store.removeFromHistory(item) }
                    )
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

/// A poster card sized to fill half the screen width (minus padding + gap).
/// Wider than the standard PosterCard so two columns look balanced.
private struct SearchPosterCard: View {
    let item: MediaItem
    var isFavorite: Bool
    var watchProgress: WatchProgress?
    var canRemoveFromHistory: Bool
    var onTap: () -> Void
    var onToggleFavorite: () -> Void
    var onRemoveFromHistory: () -> Void

    var body: some View {
        GeometryReader { geo in
            Button(action: onTap) {
                ZStack(alignment: .bottom) {
                    posterImage(width: geo.size.width)

                    LinearGradient(
                        colors: [.black.opacity(0.85), .clear],
                        startPoint: .bottom, endPoint: .center
                    )
                    .frame(height: 90)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(2)
                            .foregroundStyle(.white)
                        Text(item.year.isEmpty ? "TMDB" : item.year)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white.opacity(0.56))
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack {
                        HStack {
                            Text(item.typeLabel.uppercased())
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.black.opacity(0.45), in: Capsule())
                                .foregroundStyle(.white.opacity(0.85))
                            Spacer()
                            if isFavorite {
                                Image(systemName: "heart.fill")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.blue)
                                    .padding(6)
                                    .vixGlass(.regular, cornerRadius: 999)
                            }
                        }
                        Spacer()
                    }
                    .padding(8)

                    if let watchProgress {
                        VStack {
                            Spacer()
                            ProgressOverlay(progress: watchProgress.progress)
                                .frame(height: 4)
                        }
                        .padding(8)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(action: onTap) {
                    Label(item.resumeSeason != nil || watchProgress != nil ? "Resume" : "Play", systemImage: "play.fill")
                }
                Button(action: onToggleFavorite) {
                    Label(isFavorite ? "Remove from Favourites" : "Add to Favourites",
                          systemImage: isFavorite ? "heart.slash" : "heart")
                }
                if canRemoveFromHistory {
                    Button(role: .destructive, action: onRemoveFromHistory) {
                        Label("Remove from History", systemImage: "clock.arrow.circlepath")
                    }
                }
            }
        }
        // aspectRatio drives the GeometryReader's height
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
    }

    init(item: MediaItem, isFavorite: Bool, watchProgress: WatchProgress? = nil, canRemoveFromHistory: Bool, onTap: @escaping () -> Void, onToggleFavorite: @escaping () -> Void, onRemoveFromHistory: @escaping () -> Void) {
        self.item = item
        self.isFavorite = isFavorite
        self.watchProgress = watchProgress
        self.canRemoveFromHistory = canRemoveFromHistory
        self.onTap = onTap
        self.onToggleFavorite = onToggleFavorite
        self.onRemoveFromHistory = onRemoveFromHistory
    }

    @ViewBuilder
    private func posterImage(width: CGFloat) -> some View {
        if let url = item.posterURL {
            AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.3))) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .overlay(
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.35))
            )
    }
}
