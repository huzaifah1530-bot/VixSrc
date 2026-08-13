import SwiftUI

/// A circular Liquid Glass favourite toggle.
///
/// On iOS 26 uses `.glassEffect(.regular.interactive())` — identical to how
/// Apple's own toolbar circle buttons (e.g. the share circle in Photos) work.
/// Blue tint when favourited, neutral when not. Spring heart-pop on every tap.
/// Pre-iOS 26 falls back to a material circle with matching tint.
struct FavoriteButton: View {
    var isFavorite: Bool
    var action: () -> Void

    @Environment(\.glassFidelity) private var fidelity
    @State private var bouncing = false

    var body: some View {
        Button(action: handleTap) {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isFavorite ? Color.blue : Color.white)
                .scaleEffect(bouncing ? 1.3 : 1.0)
                .animation(.spring(response: 0.28, dampingFraction: 0.48), value: bouncing)
                .frame(width: 50, height: 50)
        }
        .buttonStyle(CircleGlassButtonStyle(isActive: isFavorite, fidelity: fidelity))
        .accessibilityLabel(isFavorite ? "Remove from favourites" : "Add to favourites")
    }

    private func handleTap() {
        bouncing = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 160_000_000)
            bouncing = false
        }
        action()
    }
}

// MARK: - Shared circle glass button style (reused by close button etc.)

struct CircleGlassButtonStyle: ButtonStyle {
    var isActive: Bool = false
    var fidelity: GlassFidelity = .full

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background { background }
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }

    @ViewBuilder
    private var background: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), fidelity == .full {
            Circle()
                .glassEffect(
                    isActive
                        ? .regular.tint(Color.blue.opacity(0.5)).interactive()
                        : .regular.tint(Color.white.opacity(0.08)).interactive(),
                    in: .circle
                )
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }

    private var fallback: some View {
        Circle()
            .fill(isActive ? Color.blue.opacity(0.25) : Color.white.opacity(0.14))
            .overlay(Circle().stroke(isActive ? Color.blue.opacity(0.5) : Color.white.opacity(0.2), lineWidth: 1))
    }
}

// MARK: - Shared capsule glass button style (for player action row)

struct CapsuleGlassButtonStyle: ButtonStyle {
    var isActive: Bool = false
    var fidelity: GlassFidelity = .full

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isActive ? Color.blue : Color.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background { background }
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }

    @ViewBuilder
    private var background: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), fidelity == .full {
            Capsule()
                .glassEffect(
                    isActive
                        ? .regular.tint(Color.blue.opacity(0.45)).interactive()
                        : .regular.tint(Color.white.opacity(0.07)).interactive(),
                    in: .capsule
                )
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }

    private var fallback: some View {
        Capsule()
            .fill(isActive ? Color.blue.opacity(0.2) : Color.white.opacity(0.1))
            .overlay(Capsule().stroke(isActive ? Color.blue.opacity(0.4) : Color.white.opacity(0.18), lineWidth: 1))
    }
}
