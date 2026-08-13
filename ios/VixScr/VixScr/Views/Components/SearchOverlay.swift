import SwiftUI
import UIKit

/// Reports a view's actual rendered height up through the view tree, so an
/// ancestor can size itself to content instead of guessing.
private struct HeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

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

    /// Measured height of the scrollable content. `ScrollView` always wants
    /// to expand to fill whatever height it's offered, so a plain
    /// `.frame(maxHeight: cap)` on it doesn't clamp down to a *small*
    /// content size — it makes the overlay reserve the full cap height even
    /// when showing one line of empty-state text. That reserved space lives
    /// inside the same safeAreaInset as the nav bar, so it pushed the whole
    /// header area (and everything below it) down by the cap amount on
    /// every focus, even with nothing to show. Measuring the real content
    /// height and taking `min(measured, cap)` fixes both: the overlay stays
    /// small when empty, and still scrolls/clamps when content is long.
    @State private var contentHeight: CGFloat = 0

    private var cappedHeight: CGFloat {
        // Uses the real window bounds (not `UIScreen.main.bounds`, which
        // reports the physical device screen and is wrong in iPad Split
        // View/Stage Manager where the app's window is smaller).
        let cap = min(HeroView.windowBounds.height * 0.6, 420)
        return min(contentHeight, cap)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(statusText.uppercased())
                .font(.system(size: 11, weight: .black))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 14)
                .padding(.top, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
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
                                        Spacer(minLength: 8)
                                        Text(item.typeLabel.uppercased())
                                            .font(.system(size: 10, weight: .black))
                                            .foregroundStyle(.white.opacity(0.6))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(Color.white.opacity(0.1), in: Capsule())
                                            .fixedSize()
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
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: HeightPreferenceKey.self, value: geo.size.height)
                    }
                )
            }
            .frame(height: cappedHeight)
            .onPreferenceChange(HeightPreferenceKey.self) { measured in
                contentHeight = measured
            }
        }
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
