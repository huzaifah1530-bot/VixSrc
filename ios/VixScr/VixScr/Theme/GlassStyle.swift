import SwiftUI

/// Liquid Glass helpers. On iOS 26+ this uses Apple's real `glassEffect()` /
/// `GlassEffectContainer` APIs (the native replacement for the CSS
/// `backdrop-filter: blur() saturate()` "glass" classes in index.html). On
/// older OS versions it falls back to a `.ultraThinMaterial` approximation
/// so the app still builds and looks reasonable back to iOS 17.
enum GlassStrength {
    /// Matches `.glass` in index.html: blur(32px) saturate(180%).
    case regular
    /// Matches `.glass-strong`: blur(42px) saturate(190%).
    case strong
}

struct LiquidGlassBackground: ViewModifier {
    var strength: GlassStrength
    var cornerRadius: CGFloat
    var tint: Color = .white.opacity(0.08)

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    strength == .strong ? .regular.tint(tint).interactive() : .regular.tint(tint),
                    in: .rect(cornerRadius: cornerRadius)
                )
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                )
        }
        #else
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
            )
        #endif
    }
}

extension View {
    /// Applies the glass surface used for cards, nav bars, sheets, chips.
    /// `performanceMode` mirrors the Electron app's Performance Mode
    /// setting, which strips all blur/backdrop effects for low-end hardware
    /// — here we substitute a flat, opaque surface instead of any glass.
    func vixGlass(_ strength: GlassStrength = .regular, cornerRadius: CGFloat = 24, performanceMode: Bool = false) -> some View {
        Group {
            if performanceMode {
                self.background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(white: 0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .stroke(Color(white: 0.2), lineWidth: 1)
                        )
                )
            } else {
                self.modifier(LiquidGlassBackground(strength: strength, cornerRadius: cornerRadius))
            }
        }
    }
}

/// Wraps a group of glass surfaces so they can morph/merge fluidly, mirroring
/// Apple's guidance to group related glass elements. Falls back to a plain
/// container pre-iOS 26.
struct VixGlassContainer<Content: View>: View {
    @ViewBuilder var content: Content

    @ViewBuilder
    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 12) { content }
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
