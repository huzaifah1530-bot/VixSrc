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
        content
            // The backdrop + gradient live in `.background` instead of a
            // sibling layer in the same ZStack. That way `.clipped()` only
            // trims the *image*, and the text/button content below is free
            // to grow the VStack (and therefore this whole view) taller
            // when a long title/description needs more room, instead of
            // being cut off by a hard-coded max height.
            .background(
                ZStack(alignment: .bottomLeading) {
                    backdrop
                    LinearGradient(colors: [.black.opacity(0.9), .black.opacity(0.2), .clear], startPoint: .bottom, endPoint: .top)
                }
                .clipped()
            )
            // Scale with the device instead of a fixed height: a healthy
            // *minimum* fraction of screen height, so the hero never looks
            // cramped, but content is always allowed to push it taller
            // rather than being silently truncated.
            .frame(minHeight: heroHeight)
    }

    private var content: some View {
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
                // 2 lines (not 3) keeps the tallest realistic title from
                // pushing the description + button row off-screen on an
                // SE-size device; `minimumScaleFactor` shrinks extra-long
                // titles instead of wrapping to a 3rd line.
                .lineLimit(2)
                .minimumScaleFactor(0.7)

            Text(item?.description ?? "Add your TMDB API key or read access token to search the live TMDB database and load seasons dynamically.")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(2)

            // Horizontally scrollable instead of a plain HStack: on
            // narrower screens (SE-size phones, or landscape where height
            // is short but this row's *ideal* width can still exceed it) a
            // fixed HStack does not wrap and instead grows past the
            // available width, which forced this whole hero block wider
            // than the screen and clipped its edges.
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
        // scrollable) can still push the whole VStack's ideal width past
        // the screen, since a view sizes itself to its content rather than
        // to its parent by default.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heroHeight: CGFloat {
        // `UIScreen.main.bounds` reports the physical device screen size,
        // not the app's actual window bounds — wrong on iPad Split
        // View/Slide Over and Stage Manager, where the window can be much
        // smaller than the screen. `windowBounds` reads the real window
        // the app is drawn into instead.
        let window = Self.windowBounds
        let isLandscape = window.width > window.height
        let shorterSide = min(window.width, window.height)
        // In landscape, cap relative to the actual (short) viewport height
        // rather than the long side, otherwise this would still overshoot.
        let reference = isLandscape ? window.height : shorterSide
        return min(max(reference * (isLandscape ? 0.7 : 0.58), 320), 460)
    }

    static var windowBounds: CGRect {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow?.bounds
            ?? UIScreen.main.bounds
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
