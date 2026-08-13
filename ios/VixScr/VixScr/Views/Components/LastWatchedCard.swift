import SwiftUI

/// A compact "Continue watching" nudge card placed just below the hero.
/// Shows the most recently watched title with its poster, resume position,
/// and a one-tap Continue button. Smaller than the hero — feels like the
/// "Up Next" strip Apple uses in the TV app above the main content rows.
struct LastWatchedCard: View {
    let item: MediaItem
    let isFavorite: Bool
    var onContinue: () -> Void
    var onFavorite: () -> Void

    @Environment(\.glassFidelity) private var fidelity

    var body: some View {
        Button(action: onContinue) {
            HStack(spacing: 14) {
                // Poster thumbnail
                posterThumb

                // Text stack
                VStack(alignment: .leading, spacing: 4) {
                    Text("CONTINUE WATCHING")
                        .font(.caption2.weight(.bold))
                        .tracking(0.5)
                        .foregroundStyle(.white.opacity(0.5))

                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    if let season = item.resumeSeason, let episode = item.resumeEpisode {
                        Text("S\(season) · E\(episode)\(item.resumeTitle.map { " · \($0)" } ?? "")")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    } else {
                        Text(item.typeLabel + (item.year.isEmpty ? "" : " · \(item.year)"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }

                Spacer(minLength: 0)

                // Play chevron
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.trailing, 4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background { cardBackground }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Poster thumbnail

    @ViewBuilder
    private var posterThumb: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(0.08))
            .frame(width: 52, height: 78)
            .overlay {
                if let url = item.posterURL {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable()
                                .scaledToFill()
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Background

    @ViewBuilder
    private var cardBackground: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), fidelity == .full {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .glassEffect(
                    .regular.tint(Color.white.opacity(0.06)).interactive(),
                    in: .rect(cornerRadius: 16)
                )
        } else {
            fallbackBackground
        }
        #else
        fallbackBackground
        #endif
    }

    private var fallbackBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
    }
}
