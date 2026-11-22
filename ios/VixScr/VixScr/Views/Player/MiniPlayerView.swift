import SwiftUI
import UIKit
import Observation

/// The video that keeps playing in the corner after the player sheet is
/// closed. One at a time; the owning view model decides what expanding and
/// closing mean (and asks a party viewer before closing).
@MainActor
@Observable
final class MiniPlayerCenter {
    static let shared = MiniPlayerCenter()

    private(set) var manager: VideoPlayerManager?
    private(set) var title = ""
    private(set) var subtitle: String?
    private(set) var artworkURL: URL?
    /// Height of the party pill, so the mini player can sit above it.
    var partyDockHeight: CGFloat = 40
    @ObservationIgnored private var expandAction: (@MainActor () -> Void)?
    @ObservationIgnored private var closeAction: (@MainActor () -> Void)?

    var isActive: Bool { manager != nil }

    private init() {}

    func show(manager: VideoPlayerManager, title: String, subtitle: String? = nil, artworkURL: URL? = nil,
              expand: @escaping @MainActor () -> Void, close: @escaping @MainActor () -> Void) {
        self.manager = manager
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        expandAction = expand
        closeAction = close
    }

    /// Just hides the card; playback carries on.
    func hide() {
        manager = nil
        title = ""
        subtitle = nil
        artworkURL = nil
        expandAction = nil
        closeAction = nil
    }

    /// Hides the card if it's showing `manager` (that player closed or reloaded).
    func release(_ manager: VideoPlayerManager) {
        if self.manager === manager { hide() }
    }

    /// A player sheet is coming up. Its own video leaves the corner; any
    /// other player is closed so two never play at once.
    func playerWillShow(_ manager: VideoPlayerManager) {
        guard let current = self.manager else { return }
        if current === manager { hide(); return }
        let close = closeAction
        hide()
        close?()
    }

    func expand() {
        let action = expandAction
        hide()
        action?()
    }

    /// Stays up until the owner actually closes (a party viewer may cancel).
    func close() {
        closeAction?()
    }
}

/// Bottom-trailing mini player, placed over the whole app (outside the
/// TabView) and kept above the tab bar and the party pill.
struct MiniPlayerOverlay: View {
    @State private var center = MiniPlayerCenter.shared
    @State private var party = PartySession.shared
    /// Distance from the window's bottom edge to the top of the tab bar;
    /// nil until found.
    @State private var tabBarCover: CGFloat?
    @State private var measureTask: Task<Void, Never>?
    @State private var drag: CGSize = .zero

    private let spring = Animation.spring(response: 0.42, dampingFraction: 0.86)

    var body: some View {
        GeometryReader { proxy in
            let fullWidth = proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing
            let cardWidth = videoWidth(for: fullWidth)
            ZStack(alignment: .bottomTrailing) {
                Color.clear
                    .allowsHitTesting(false)
                if let manager = center.manager {
                    MiniPlayerCard(manager: manager, title: center.title,
                                   onExpand: { expand() }, onClose: { center.close() })
                        .frame(width: cardWidth, height: cardWidth * 9 / 16)
                        // A thin glass rim around the video.
                        .padding(3)
                        .vixGlass(.regular, cornerRadius: 19)
                        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                        .offset(drag)
                        .simultaneousGesture(dragGesture)
                        .padding(.trailing, 14)
                        .padding(.bottom, bottomLift(safeBottom: proxy.safeAreaInsets.bottom))
                        .transition(
                            .move(edge: .bottom)
                                .combined(with: .scale(scale: 0.85, anchor: .bottomTrailing))
                                .combined(with: .opacity)
                        )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomTrailing)
            .animation(spring, value: center.isActive)
            .animation(spring, value: party.active)
            .onAppear { remeasure() }
            // Rotation, split view, window resizes.
            .onChange(of: proxy.size) { _, _ in remeasure() }
        }
        // The keyboard covers the tab bar anyway; don't jump above it.
        .ignoresSafeArea(.keyboard)
        .onChange(of: center.isActive) { _, active in if active { remeasure() } }
        // Asks at the app level (mini player close, opening a title).
        .partyLeaveConfirmation(.root)
    }

    /// ~46% of the screen width, 168–260pt on iPhone.
    private func videoWidth(for screenWidth: CGFloat) -> CGFloat {
        let maxWidth: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 360 : 260
        return min(maxWidth, max(168, screenWidth * 0.46)) - 6
    }

    /// Space above the safe area's bottom edge: clear of the tab bar, and of
    /// the party pill (which sits 84pt up) while a party is on.
    private func bottomLift(safeBottom: CGFloat) -> CGFloat {
        let bar: CGFloat
        if let tabBarCover {
            bar = max(0, tabBarCover - safeBottom)
        } else if #available(iOS 18.0, *), UIDevice.current.userInterfaceIdiom == .pad {
            bar = 0 // iPad shows its tabs at the top
        } else {
            bar = 49 // classic tab bar height
        }
        var lift = bar + 12
        if party.active { lift = max(lift, 84 + center.partyDockHeight + 10) }
        return lift
    }

    private func remeasure() {
        tabBarCover = TabBarProbe.coveredBottom()
        // Layout may still be settling (launch, rotation): look again shortly.
        measureTask?.cancel()
        measureTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            tabBarCover = TabBarProbe.coveredBottom()
        }
    }

    private func expand() {
        withAnimation(spring) { center.expand() }
    }

    /// Up expands, down closes; anything shorter springs back.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // Follows the finger vertically, resists sideways.
                drag = CGSize(width: value.translation.width * 0.3, height: value.translation.height)
            }
            .onEnded { value in
                let moved = value.translation.height
                let flung = value.predictedEndTranslation.height
                if moved > 70 || flung > 240 {
                    center.close()
                } else if moved < -70 || flung < -240 {
                    expand()
                }
                withAnimation(spring) { drag = .zero }
            }
    }
}

/// Live video with play / pause, close and a progress line.
private struct MiniPlayerCard: View {
    let manager: VideoPlayerManager
    let title: String
    let onExpand: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black
            VideoPlayerLayer(player: manager.player, isFullscreen: false, fillsFrame: true)
                .allowsHitTesting(false)
            if manager.isLoading {
                ProgressView().tint(.white)
            }
            // Tap the video to go back to the full player.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onExpand() }
                .accessibilityElement()
                .accessibilityLabel(title.isEmpty ? "Mini player" : "\(title), mini player")
                .accessibilityHint("Opens the player")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default) { onExpand() }
            controls
        }
        .overlay(alignment: .bottom) { progressLine }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                disc("xmark", label: "Close mini player") { onClose() }
            }
            Spacer(minLength: 0)
            HStack {
                disc(manager.isPlaying ? "pause.fill" : "play.fill", label: manager.isPlaying ? "Pause" : "Play") {
                    manager.togglePlayPause()
                }
                Spacer(minLength: 0)
            }
        }
        .padding(2)
    }

    private func disc(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 30)
                .vixGlass(.regular, cornerRadius: 15)
        }
        // 44pt hit target around the 30pt disc.
        .buttonStyle(PlayerButtonStyle())
        .accessibilityLabel(label)
    }

    private var progressLine: some View {
        let progress = min(max(manager.progress, 0), 1)
        return ZStack(alignment: .leading) {
            Rectangle().fill(Color.white.opacity(0.22))
            Rectangle().fill(Color.white)
                .scaleEffect(x: progress, y: 1, anchor: .leading)
        }
        .frame(height: 3)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Reads the real tab bar from UIKit, so the mini player clears it on every
/// device: the classic bar, the iOS 26 floating glass bar, or none at the
/// bottom (iPad tabs at the top).
@MainActor
private enum TabBarProbe {
    /// Height the tab bar covers from the window's bottom edge; 0 when it
    /// isn't at the bottom, nil when there's no tab bar to measure.
    static func coveredBottom() -> CGFloat? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first,
              let controller = tabBarController(in: window.rootViewController) else { return nil }
        let bar = controller.tabBar
        guard !bar.isHidden, bar.alpha > 0.01, bar.window === window, bar.bounds.height > 0 else { return nil }
        let frame = bar.convert(bar.bounds, to: window)
        guard frame.minY > window.bounds.midY else { return 0 }
        return max(0, window.bounds.maxY - frame.minY)
    }

    private static func tabBarController(in controller: UIViewController?) -> UITabBarController? {
        guard let controller else { return nil }
        if let tabs = controller as? UITabBarController { return tabs }
        for child in controller.children {
            if let found = tabBarController(in: child) { return found }
        }
        return nil
    }
}
