import SwiftUI

/// Mirrors `#searchOverlay` — recent search chips + live/fuzzy result rows,
/// shown below the search field while it has focus or text.
struct SearchOverlay: View {
    let query: String
    let items: [MediaItem]
    let recentSearches: [String]
    var statusText: String
    var onSelectRecent: (String) -> Void
    var onSelectItem: (MediaItem) -> Void
    var onClearRecents: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(statusText.uppercased())
                .font(.system(size: 11, weight: .black))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 14)
                .padding(.top, 12)

            if !recentSearches.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("RECENT SEARCHES")
                            .font(.system(size: 10, weight: .black))
                            .tracking(2)
                            .foregroundStyle(.white.opacity(0.38))
                        Spacer()
                        Button("Clear", action: onClearRecents)
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(recentSearches, id: \.self) { search in
                                Button(search) { onSelectRecent(search) }
                                    .font(.system(size: 12, weight: .black))
                                    .foregroundStyle(.white.opacity(0.75))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(Color.white.opacity(0.08), in: Capsule())
                                    .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
            }

            if items.isEmpty {
                Text(query.trimmingCharacters(in: .whitespaces).isEmpty
                     ? "Start typing, or pick a recent search above."
                     : "No close TMDB matches yet. Try removing extra words, or adding a year like \u{201c}Batman 2022\u{201d}.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(14)
            } else {
                VStack(spacing: 8) {
                    ForEach(items.prefix(8)) { item in
                        Button { onSelectItem(item) } label: {
                            HStack(spacing: 12) {
                                posterThumb(for: item)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.system(size: 14, weight: .black))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Text(item.description)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(0.55))
                                        .lineLimit(2)
                                }
                                Spacer()
                                Text(item.typeLabel.uppercased())
                                    .font(.system(size: 10, weight: .black))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.white.opacity(0.1), in: Capsule())
                            }
                            .padding(8)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.bottom, 14)
        .vixGlass(.strong, cornerRadius: 28)
    }

    @ViewBuilder
    private func posterThumb(for item: MediaItem) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.1))
            .frame(width: 46, height: 68)
            .overlay {
                if let url = item.posterURL {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }
            }
    }
}
