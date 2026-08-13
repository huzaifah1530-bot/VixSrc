import SwiftUI

/// Mirrors the row rendering inside `renderRows()` — a titled horizontal
/// shelf of poster cards.
struct MediaRowView: View {
    let row: MediaRow
    let store: AppStore
    let onSelect: (MediaItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Text(row.subtitle)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(row.items) { item in
                        PosterCard(
                            item: item,
                            isFavorite: store.isFavorite(item),
                            compact: store.cardSize == .compact,
                            onTap: { onSelect(item) }
                        )
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}
