import SwiftUI

/// Mirrors `createPosterCard()` — a poster thumbnail with type badge,
/// favourite badge, resume ribbon, and a title/year caption gradient.
struct PosterCard: View {
    let item: MediaItem
    var isFavorite: Bool
    var compact: Bool
    var watchProgress: WatchProgress?
    var widthOverride: CGFloat?
    var onTap: () -> Void

    private var width: CGFloat { widthOverride ?? (compact ? 124 : 154) }
    private var cornerRadius: CGFloat { compact ? 18 : 22 }

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottom) {
                posterImage

                LinearGradient(colors: [.black.opacity(0.85), .clear], startPoint: .bottom, endPoint: .center)
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
                    if let season = item.resumeSeason, let episode = item.resumeEpisode {
                        Text("RESUME S\(season) E\(episode)")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                            .background(.white.opacity(0.13), in: Capsule())
                            .foregroundStyle(.white.opacity(0.86))
                    }
                }
                .padding(8)

                if let watchProgress {
                    VStack {
                        Spacer()
                        ProgressOverlay(progress: watchProgress.progress)
                            .frame(height: 4)
                    }
                }
            }
            .frame(width: width, height: width * 1.5)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    init(item: MediaItem, isFavorite: Bool, compact: Bool, watchProgress: WatchProgress? = nil, widthOverride: CGFloat? = nil, onTap: @escaping () -> Void) {
        self.item = item
        self.isFavorite = isFavorite
        self.compact = compact
        self.watchProgress = watchProgress
        self.widthOverride = widthOverride
        self.onTap = onTap
    }

    @ViewBuilder
    private var posterImage: some View {
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
