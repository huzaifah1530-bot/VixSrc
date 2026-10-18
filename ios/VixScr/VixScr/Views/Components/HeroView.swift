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
        // Anime catalogue titles only have portrait posters, which crop
        // badly into a 16:9 banner. Show them poster-left instead.
        if let item, item.isAnimeCatalog {
            posterLayout(item)
        } else {
            bannerLayout
        }
    }

    private func posterLayout(_ item: MediaItem) -> some View {
        HStack(alignment: .top, spacing: 16) {
            AsyncImage(url: item.posterURL, transaction: Transaction(animation: .easeInOut(duration: 0.35))) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill().transition(.opacity)
                } else {
                    Color(white: 0.04)
                }
            }
            .frame(width: 120, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .id(item.posterURL)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text(tagText.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(0.5)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .vixGlass(.regular, cornerRadius: 999)

                Text(item.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)

                Text(item.year)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    Button(action: onPlay) {
                        Label("Play", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    FavoriteButton(isFavorite: isFavorite, action: onToggleFavorite)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 180, alignment: .topLeading)
        }
        .padding(16)
        .frame(maxWidth: 720)
        .background(Color(white: 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .id(item.id)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.8), value: item.id)
    }

    private var bannerLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            backdrop
                // Keep the media area proportional while capping it on iPad.
                // A fixed height made the loaded artwork feel like it changed
                // the surrounding padding on different device widths.
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
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
                        // Tag text fades with the rest of the card content.
                        .id(item?.id)
                        .transition(.opacity)
                }

            VStack(alignment: .leading, spacing: 10) {
                Text(item?.title ?? "Connect TMDB")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Each distinct item gets its own identity so the title
                    // cross-fades rather than animating a text content change
                    // (which would look like a scramble, not a dissolve).
                    .id(item?.id)
                    .transition(.opacity)

                Text(item?.description ?? "Add your TMDB API key or read access token to browse the live TMDB catalogue.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(item?.id)
                    .transition(.opacity)

                // Button row: Play stretches to fill, fav circle is fixed 50pt.
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
                        FavoriteButton(isFavorite: isFavorite, action: onToggleFavorite)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            // Animate the whole text+button area as a unit when item changes.
            // easeInOut(0.8) matches the backdrop dissolve duration so both
            // layers finish at the same time — feels like a single cohesive
            // transition rather than backdrop and text finishing separately.
            .animation(.easeInOut(duration: 0.8), value: item?.id)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxWidth: 720)
        .background(Color(white: 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var tagText: String {
        guard let item else { return "Live TMDB" }
        if item.isAnimeCatalog { return "Anime" }
        return item.typeLabel + (item.year.isEmpty ? "" : " · \(item.year)")
    }

    @ViewBuilder
    private var backdrop: some View {
        if let url = item?.backdropURL, glassFidelity != .opaque {
            AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.35))) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                        // Fade the image in once loaded. Using .transition here
                        // rather than on the AsyncImage itself means only the
                        // image pixels dissolve — the card shape and layout
                        // never re-render, so the corner-radius / clip never
                        // flickers during a hero cycle.
                        .transition(.opacity)
                } else {
                    // Placeholder shown while loading or on failure. Stable
                    // dark surface — never transparent, so no shape flash.
                    Color(white: 0.04)
                }
            }
            // Give each URL its own identity. When the hero cycles, SwiftUI
            // replaces the old AsyncImage with a new one, animating the
            // cross-dissolve between the cached outgoing image and the
            // incoming one — only the image layer dissolves, the card
            // container stays put.
            .id(url)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.8), value: url)
        } else {
            Color(white: 0.04)
        }
    }
}
