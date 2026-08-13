import SwiftUI
import UIKit

/// A featured-title card at the top of Home. Styled like Apple's own
/// featured-content cards (App Store "Today" cards, TV app "Up Next"),
/// rather than a full-bleed web-style hero banner: a rounded card with a
/// backdrop image, a short title/description, and native button styles.
struct HeroView: View {
    let item: MediaItem?
    let hasCredential: Bool
    var onPlay: () -> Void
    var onSetup: () -> Void
    var onToggleFavorite: () -> Void
    var isFavorite: Bool

    @Environment(\.glassFidelity) private var glassFidelity

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            backdrop
                .frame(height: 220)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    LinearGradient(colors: [.black.opacity(0.85), .clear], startPoint: .bottom, endPoint: .top)
                        .frame(height: 120)
                        .frame(maxWidth: .infinity)
                }
                .overlay(alignment: .topLeading) {
                    Text(tagText.uppercased())
                        .font(.caption2.weight(.bold))
                        .tracking(0.5)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .vixGlass(.regular, cornerRadius: 999)
                        .padding(12)
                }

            VStack(alignment: .leading, spacing: 10) {
                Text(item?.title ?? "Connect TMDB")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)

                Text(item?.description ?? "Add your TMDB API key or read access token to search the live TMDB database and load seasons dynamically.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)

                HStack(spacing: 10) {
                    if item != nil {
                        Button(action: onPlay) {
                            Label("Play", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.white)
                        .foregroundStyle(.black)
                    }

                    if !hasCredential {
                        Button(action: onSetup) {
                            Label("Add TMDB Key", systemImage: "key.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.white)
                        .foregroundStyle(.black)
                    }

                    if item != nil {
                        Button(action: onToggleFavorite) {
                            Image(systemName: isFavorite ? "heart.fill" : "heart")
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .accessibilityLabel(isFavorite ? "Remove from favourites" : "Add to favourites")
                    }
                }
                .controlSize(.large)
            }
            .padding(16)
        }
        .background(Color(white: 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var tagText: String {
        guard let item else { return "Live TMDB" }
        return item.typeLabel + (item.year.isEmpty ? "" : " · \(item.year)")
    }

    /// Ultra performance mode hides backdrop images entirely, matching
    /// `body.ultra-perf-mode` in index.html.
    @ViewBuilder
    private var backdrop: some View {
        if let url = item?.backdropURL, glassFidelity != .opaque {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Color(white: 0.04)
                }
            }
        } else {
            Color(white: 0.04)
        }
    }
}
