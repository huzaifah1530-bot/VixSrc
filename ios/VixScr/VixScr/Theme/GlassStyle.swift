import SwiftUI

/// Liquid Glass helpers. On iOS 26+ this uses Apple's real `glassEffect()` /
/// `GlassEffectContainer` APIs (the native replacement for the CSS
/// `backdrop-filter: blur() saturate()` "glass" classes in index.html). On
/// older OS versions it falls back to a material approximation so the app
/// still builds and looks reasonable back to iOS 17.
///
/// IMPORTANT: the iOS 26 branch is gated on `#if compiler(>=6.2)` because
/// `glassEffect` / `GlassEffectContainer` only exist in the iOS 26 SDK.
/// Building with an older toolchain (e.g. Xcode 16.4 / iOS 18.5 SDK) compiles
/// the fallback everywhere. The CI workflow deliberately selects Xcode 26 so
/// release builds ship the real glass; `#available(iOS 26.0, *)` then keeps
/// iOS 17–25 devices on the fallback at runtime.
enum GlassStrength {
    /// Matches `.glass` in index.html: blur(32px) saturate(180%).
    case regular
    /// Matches `.glass-strong`: blur(42px) saturate(190%).
    case strong
}

/// How much glass to render. Mirrors the Electron app's two display settings,
/// which in index.html toggle `body.perf-mode` / `body.ultra-perf-mode` and
/// strip backdrop-filter entirely on low-end hardware.
enum GlassFidelity {
    /// Full Liquid Glass (or material fallback).
    case full
    /// Performance mode: no blur, flat translucent surface.
    case flat
    /// Ultra performance mode: no blur, fully opaque surface, no gradients.
    case opaque
}

struct LiquidGlassBackground: ViewModifier {
    var strength: GlassStrength
    var cornerRadius: CGFloat
    var tint: Color = .white.opacity(0.08)

    /// Read from the environment so Performance Mode applies app-wide, the
    /// same way `body.perf-mode` did in the web app — rather than requiring
    /// every one of the ~23 call sites to thread the flag through by hand.
    @Environment(\.glassFidelity) private var fidelity

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        switch fidelity {
        case .full:
            glassBody(content)
        case .flat:
            content.background(
                shape
                    .fill(Color.white.opacity(strength == .strong ? 0.14 : 0.10))
                    .overlay(shape.stroke(Color.white.opacity(0.18), lineWidth: 1))
            )
        case .opaque:
            content.background(
                shape
                    .fill(Color(white: strength == .strong ? 0.10 : 0.07))
                    .overlay(shape.stroke(Color(white: 0.2), lineWidth: 1))
            )
        }
    }

    @ViewBuilder
    private func glassBody(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            // `.strong` gets a heavier tint and interactivity, standing in for
            // the web app's stronger blur/saturation on `.glass-strong`.
            content
                .glassEffect(
                    strength == .strong
                        ? .regular.tint(tint.opacity(0.9)).interactive()
                        : .regular.tint(tint),
                    in: .rect(cornerRadius: cornerRadius)
                )
        } else {
            materialFallback(content)
        }
        #else
        materialFallback(content)
        #endif
    }

    /// Pre-iOS 26 approximation. `.strong` uses a denser material so the two
    /// strengths remain visually distinct, matching `.glass` vs `.glass-strong`.
    @ViewBuilder
    private func materialFallback(_ content: Content) -> some View {
        content.background(
            shape
                .fill(strength == .strong ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.ultraThinMaterial))
                .overlay(shape.stroke(Color.white.opacity(0.2), lineWidth: 1))
        )
    }
}

// MARK: - Environment plumbing

private struct GlassFidelityKey: EnvironmentKey {
    static let defaultValue: GlassFidelity = .full
}

extension EnvironmentValues {
    var glassFidelity: GlassFidelity {
        get { self[GlassFidelityKey.self] }
        set { self[GlassFidelityKey.self] = newValue }
    }
}

extension GlassFidelity {
    /// Maps the two persisted Electron display settings onto a fidelity level.
    /// Ultra implies performance mode, exactly as in index.html.
    init(performanceMode: Bool, ultraPerformanceMode: Bool) {
        if ultraPerformanceMode {
            self = .opaque
        } else if performanceMode {
            self = .flat
        } else {
            self = .full
        }
    }
}

extension View {
    /// Applies the glass surface used for cards, nav bars, sheets, chips.
    func vixGlass(_ strength: GlassStrength = .regular, cornerRadius: CGFloat = 24) -> some View {
        modifier(LiquidGlassBackground(strength: strength, cornerRadius: cornerRadius))
    }

    /// Sets the app-wide glass fidelity from the persisted display settings.
    func vixGlassFidelity(performanceMode: Bool, ultraPerformanceMode: Bool) -> some View {
        environment(
            \.glassFidelity,
            GlassFidelity(performanceMode: performanceMode, ultraPerformanceMode: ultraPerformanceMode)
        )
    }
}

/// Wraps a group of glass surfaces so they can morph/merge fluidly, mirroring
/// Apple's guidance to group related glass elements. Falls back to a plain
/// container pre-iOS 26 (and when Performance Mode is on, since there is no
/// glass left to merge).
struct VixGlassContainer<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    @Environment(\.glassFidelity) private var fidelity

    @ViewBuilder
    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), fidelity == .full {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

enum VixTheme {
    static let background = Color.black
    static let cardBackground = Color.white.opacity(0.10)
    static let hairline = Color.white.opacity(0.20)
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.6)
    static let tertiaryText = Color.white.opacity(0.45)

    static let backgroundGradient = LinearGradient(
        colors: [Color(white: 0.02), .black, Color(white: 0.02)],
        startPoint: .top,
        endPoint: .bottom
    )
}
