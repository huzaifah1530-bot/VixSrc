import SwiftUI

/// Featured-title card at the top of Home. Apple TV / App Store "Today" card
/// style: rounded card, backdrop image, short title/description, native buttons.
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
                    LinearGradient(
                        colors: [.black.opacity(0.85), .clear],
                        startPoint: .bottom, endPoint: .top
                    )
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
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(item?.description ?? "Add your TMDB API key or read access token to browse the live TMDB catalogue.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Button row: Play stretches to fill, fav circle is fixed 50pt.
                // Using GeometryReader-free layout: HStack lets Play take all
                // remaining space via .frame(maxWidth: .infinity).
                HStack(spacing: 12) {
                    if item != nil {
                        Button(action: onPlay) {
                            Label("Play", systemImage: "play.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(.white, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    if !hasCredential {
                        Button(action: onSetup) {
                            Label("Add TMDB Key", systemImage: "key.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(.white, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    if item != nil {
                        // Fixed-size circle — never pushes the card edge.
                        FavoriteButton(isFavorite: isFavorite, action: onToggleFavorite)
                    }
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var tagText: String {
        guard let item else { return "Live TMDB" }
        return item.typeLabel + (item.year.isEmpty ? "" : " · \(item.year)")
    }

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
