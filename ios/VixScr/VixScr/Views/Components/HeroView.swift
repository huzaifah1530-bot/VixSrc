import SwiftUI
import UIKit

/// Mirrors the `#hero` section — a full-bleed backdrop with title,
/// description, and action buttons (Play / Add TMDB Key / Browse /
/// Favourite).
struct HeroView: View {
    let item: MediaItem?
    let hasCredential: Bool
    var onPlay: () -> Void
    var onSetup: () -> Void
    var onBrowse: () -> Void
    var onToggleFavorite: () -> Void
    var isFavorite: Bool

    @Environment(\.glassFidelity) private var glassFidelity

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            backdrop

            LinearGradient(colors: [.black.opacity(0.9), .black.opacity(0.2), .clear], startPoint: .bottom, endPoint: .top)

            VStack(alignment: .leading, spacing: 16) {
                Label(tagText, systemImage: "sparkles")
                    .font(.system(size: 12, weight: .black))
                    .tracking(2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .vixGlass(.regular, cornerRadius: 999)
                    .foregroundStyle(.white.opacity(0.8))

                Text(item?.title ?? "Connect TMDB")
                    .font(.system(size: 42, weight: .black))
                    .tracking(-1)
                    .foregroundStyle(.white)
                    .shadow(radius: 12)
                    .lineLimit(3)

                Text(item?.description ?? "Add your TMDB API key or read access token to search the live TMDB database and load seasons dynamically.")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(3)

                // Horizontally scrollable instead of a plain HStack: on
                // narrower screens (SE-size phones, or landscape where
                // height is short but this row's *ideal* width can still
                // exceed it) a fixed HStack does not wrap and instead grows
                // past the available width, which forced this whole hero
                // block wider than the screen and clipped its edges.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        if item != nil {
                            Button(action: onPlay) {
                                Label("Play", systemImage: "play.fill")
                                    .font(.system(size: 14, weight: .black))
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 12)
                            }
                            .foregroundStyle(.black)
                            .background(.white, in: Capsule())
                        }

                        if !hasCredential {
                            Button(action: onSetup) {
                                Label("Add TMDB Key", systemImage: "key.fill")
                                    .font(.system(size: 14, weight: .black))
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 12)
                            }
                            .foregroundStyle(.black)
                            .background(.white, in: Capsule())
                        }

                        Button(action: onBrowse) {
                            Label("Browse", systemImage: "rectangle.grid.1x3.fill")
                                .font(.system(size: 14, weight: .black))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                        }
                        .foregroundStyle(.white)
                        .vixGlass(.regular, cornerRadius: 999)

                        if item != nil {
                            Button(action: onToggleFavorite) {
                                Label(isFavorite ? "Favourited" : "Favourite", systemImage: isFavorite ? "heart.fill" : "heart")
                                    .font(.system(size: 14, weight: .black))
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 12)
                            }
                            .foregroundStyle(.white)
                            .vixGlass(.regular, cornerRadius: 999)
                        }
                    }
                }
            }
            .padding(24)
            // Clamp to the available width explicitly. Without this, an
            // oversized child (like the button row above, before it was
            // scrollable) can still push the whole VStack's ideal width
            // past the screen, since ZStack sizes itself to the largest
            // child rather than to its parent.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // A fixed 460pt was taller than the entire landscape viewport on
        // every iPhone (max ~430pt tall), and ate ~70% of an iPhone SE's
        // portrait screen before any content below it was visible. Scale
        // with the device instead: a healthy fraction of height, clamped
        // to a sane range so it never gets absurdly short or tall.
        .frame(height: heroHeight)
        .clipped()
    }

    private var heroHeight: CGFloat {
        let screen = UIScreen.main.bounds
        let isLandscape = screen.width > screen.height
        let shorterSide = min(screen.width, screen.height)
        // In landscape, cap relative to the actual (short) viewport height
        // rather than the long side, otherwise this would still overshoot.
        let reference = isLandscape ? screen.height : shorterSide
        return min(max(reference * (isLandscape ? 0.7 : 0.58), 320), 460)
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
