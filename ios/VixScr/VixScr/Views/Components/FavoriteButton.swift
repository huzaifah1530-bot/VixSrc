import SwiftUI

/// A Liquid Glass favourite toggle button.
///
/// On iOS 26 this uses `.glassEffect(.regular.interactive())` — the same API
/// Apple uses for their own glass toolbar buttons. When favourited, the glass
/// tints blue (matching the system selection colour) and the heart icon fills.
/// A spring scale pulse plays on every toggle for tactile feedback.
///
/// On iOS 17–25 it falls back to a standard `.bordered` button with a white
/// tint, keeping the same behaviour with a simpler look.
struct FavoriteButton: View {
    var isFavorite: Bool
    var action: () -> Void

    @Environment(\.glassFidelity) private var fidelity
    @Environment(\.controlSize) private var controlSize

    /// Drives the scale bounce on toggle.
    @State private var bouncing = false

    private var iconName: String {
        isFavorite ? "heart.fill" : "heart"
    }

    /// The accent colour: blue when active (matches iOS selection tint),
    /// white when inactive.
    private var iconColor: Color {
        isFavorite ? Color.blue : Color.white
    }

    var body: some View {
        Button(action: handleTap) {
            Image(systemName: iconName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 22, height: 22)
                // Spring scale pulse — pops on every tap.
                .scaleEffect(bouncing ? 1.28 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.5), value: bouncing)
        }
        .buttonStyle(GlassFavoriteButtonStyle(isFavorite: isFavorite, fidelity: fidelity))
        .accessibilityLabel(isFavorite ? "Remove from favourites" : "Add to favourites")
    }

    private func handleTap() {
        // Trigger the bounce, then snap back after the spring settles.
        bouncing = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            bouncing = false
        }
        action()
    }
}

// MARK: - Button style

/// Renders the Liquid Glass pill on iOS 26, falls back to `.bordered` below.
private struct GlassFavoriteButtonStyle: ButtonStyle {
    var isFavorite: Bool
    var fidelity: GlassFidelity

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background {
                glassBackground(pressed: configuration.isPressed)
            }
            // Pressed state: slight dimming, matches system button feedback.
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }

    @ViewBuilder
    private func glassBackground(pressed: Bool) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), fidelity == .full {
            // On iOS 26: real Liquid Glass with interactive highlight.
            // Blue tint when favourited — the same treatment Apple uses for
            // selected glass toolbar items (e.g. Notes formatting bar).
            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .glassEffect(
                    isFavorite
                        ? .regular.tint(Color.blue.opacity(0.55)).interactive()
                        : .regular.tint(Color.white.opacity(0.08)).interactive(),
                    in: .capsule
                )
        } else {
            fallbackBackground
        }
        #else
        fallbackBackground
        #endif
    }

    /// Pre-iOS 26 / performance mode fallback.
    private var fallbackBackground: some View {
        Capsule(style: .continuous)
            .fill(
                isFavorite
                    ? Color.blue.opacity(0.28)
                    : Color.white.opacity(0.12)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        isFavorite ? Color.blue.opacity(0.55) : Color.white.opacity(0.22),
                        lineWidth: 1
                    )
            )
    }
}
