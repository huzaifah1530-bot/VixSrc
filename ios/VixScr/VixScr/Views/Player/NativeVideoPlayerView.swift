import SwiftUI
import AVFoundation
import AVKit
import UIKit
import MediaAccessibility
import Translation

/// Native video player: AVPlayerLayer plus Vela's own controls, used both
/// inline and in fullscreen (no system AVPlayerViewController).
///
/// Gestures:
///   - tap the middle: play / pause and show the controls
///   - tap the left / right third: show / hide controls
///   - double-tap left / right third: skip back / forward (Settings → Player)
///   - hold left / right third: 2× speed while held
///   - pinch: zoom the picture (snaps to fill and to the original frame)
struct NativeVideoPlayerView: View {
    @Bindable var playerManager: VideoPlayerManager
    var onPlaybackFailure: (() -> Void)? = nil
    var options = PlayerOptions()
    @AppStorage("vela_rotate_clockwise") private var rotateClockwise = true
    /// Lives on the manager so fullscreen survives the player view being
    /// rebuilt between episodes (Next Episode while in fullscreen).
    private var isFullscreen: Bool {
        get { playerManager.wantsFullscreen }
        nonmutating set { playerManager.wantsFullscreen = newValue }
    }

    var body: some View {
        @Bindable var playerManager = playerManager
        PlayerSurface(playerManager: playerManager, isFullscreen: false, options: options) {
            setFullscreen(true)
        }
        .onAppear {
            if playerManager.player != nil && !playerManager.isPlaying { playerManager.play() }
        }
        .onDisappear {
            // Local only: a view going away must not pause a watch party.
            // Shrinking into the mini player keeps it playing.
            if !isFullscreen && !playerManager.keepsPlayingWhenHidden { playerManager.rawPause() }
        }
        .onChange(of: playerManager.error) { _, error in
            if error != nil { onPlaybackFailure?() }
        }
        .fullScreenCover(isPresented: $playerManager.wantsFullscreen, onDismiss: {
            if !isFullscreen { OrientationLock.rotateToPortraitThenUnlock() }
        }) {
            // The surface keeps its controls inside the safe area and runs
            // only its video canvas under the notch and home indicator.
            PlayerSurface(playerManager: playerManager, isFullscreen: true, options: options) {
                setFullscreen(false)
            }
            .background(Color.black.ignoresSafeArea())
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
            .preferredColorScheme(.dark)
            // The cover hides every other presenter, so it asks itself.
            .partyLeaveConfirmation(.fullscreen)
        }
    }

    private func setFullscreen(_ on: Bool) {
        isFullscreen = on
        if on {
            OrientationLock.rotate(to: rotateClockwise ? .landscapeRight : .landscapeLeft)
        } else {
            OrientationLock.rotateToPortraitThenUnlock()
        }
    }
}

// MARK: - Player surface

/// Video, captions, gesture zones and controls. Shared by the inline and
/// fullscreen presentations so both behave identically.
///
/// Two layers: a full-bleed canvas (video, scrims, gesture zones, seek
/// ripples) that ignores the safe area in fullscreen, and the controls,
/// captions and badges, which stay inside it. Neither depends on the video's
/// aspect ratio.
private struct PlayerSurface: View {
    @Bindable var playerManager: VideoPlayerManager
    let isFullscreen: Bool
    let options: PlayerOptions
    let onToggleFullscreen: () -> Void

    @Environment(AppStore.self) private var store
    @AppStorage("vela_rotate_clockwise") private var rotateClockwise = true
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var showGeneratedCaptionError = false

    // Seek ripples. Each side has its own content, visibility and fade timer
    // so both can show at once and neither glow ever moves across.
    @State private var leftRipple = SeekRipple()
    @State private var rightRipple = SeekRipple()
    @State private var leftRippleVisible = false
    @State private var rightRippleVisible = false
    @State private var leftRippleTask: Task<Void, Never>?
    @State private var rightRippleTask: Task<Void, Never>?

    @GestureState private var holdingSide: Side?
    @State private var boostSide: Side?
    @State private var lastHoldEnded = Date.distantPast
    @State private var showSpeedBadge = false
    @State private var speedBadgeTask: Task<Void, Never>?

    // Zoom. `zoomRaw` follows the fingers; `zoomScale` is what is shown,
    // with rubber-banding past the upper limit.
    @State private var zoomScale: CGFloat = 1
    @State private var zoomRaw: CGFloat = 1
    @State private var zoomOffset: CGSize = .zero
    @State private var zoomFilled = false
    /// Mirrors `zoomFilled` for the Settings menu toggle.
    @State private var fillToggle = false
    @State private var isPinching = false
    @State private var pinchAnchor: CGPoint?
    @State private var pinchTouches = 0
    @State private var zoomBadge: String?
    @State private var zoomBadgeTask: Task<Void, Never>?
    @State private var canvasSize: CGSize = .zero
    @State private var videoSize: CGSize = .zero

    @State private var playFlash: PlayFlash?
    @State private var playFlashTask: Task<Void, Never>?

    enum Side { case left, right }

    struct SeekRipple: Equatable {
        var seconds = 0
        var pulse = 0
    }

    struct PlayFlash: Equatable {
        var icon: String
        var id: Int
    }

    private static let lastCaptionKey = "vela_caption_last_ios"

    private let spring = Animation.spring(response: 0.2, dampingFraction: 0.9)
    private let zoomSpring = Animation.spring(response: 0.38, dampingFraction: 0.84)

    private var hasNextEpisodeVisible: Bool {
        options.nextEpisodeLabel != nil && options.onNextEpisode != nil &&
        playerManager.duration.isFinite && playerManager.duration > 0 &&
        playerManager.duration - playerManager.currentTime <= 300
    }

    private var captionsOn: Bool {
        playerManager.selectedSubtitleIndex != nil || playerManager.selectedExternalSubtitleIndex != nil ||
        playerManager.generatedCaptionLocale != nil
    }

    var body: some View {
        ZStack {
            canvas
            foreground
        }
        .background {
            if #available(iOS 18.0, *) {
                CaptionTranslationBridge(playerManager: playerManager,
                                         active: (isFullscreen || !playerManager.wantsFullscreen) && playerManager.translateGeneratedCaptions)
            }
        }
        .animation(spring, value: showControls)
        .animation(spring, value: playerManager.isLoading)
        .alert("Generated captions unavailable", isPresented: $showGeneratedCaptionError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(playerManager.generatedCaptionError ?? "Could not generate captions for this video.")
        }
        .onChange(of: playerManager.generatedCaptionError) { _, error in
            if error != nil { showGeneratedCaptionError = true }
        }
        .onChange(of: captionChoiceKey) { _, key in rememberCaptionChoice(key) }
        .onAppear {
            scheduleHide()
            rememberCaptionChoice(captionChoiceKey)
        }
        .task { await watchVideoSize() }
        .onDisappear {
            speedBadgeTask?.cancel()
            leftRippleTask?.cancel()
            rightRippleTask?.cancel()
            zoomBadgeTask?.cancel()
            playFlashTask?.cancel()
            playerManager.endSpeedBoost()
            boostSide = nil
            showSpeedBadge = false
            if isPinching {
                isPinching = false
                applyZoom(PlayerZoomState.load())
            }
        }
        .onChange(of: playerManager.isPlaying) { _, playing in
            if playing { scheduleHide() } else { reveal(autoHide: false) }
        }
        .onChange(of: playerManager.isSpeedBoosted) { _, boosted in
            if boosted { showSpeedBadge = true }
        }
        .onChange(of: playerManager.wantsFullscreen) { _, _ in
            playerManager.endSpeedBoost()
            boostSide = nil
            showSpeedBadge = false
            // The other surface may have changed the zoom.
            if !isPinching { applyZoom(PlayerZoomState.load()) }
        }
        .onChange(of: canvasSize) { _, _ in
            // Rotation / resize: re-fit, re-fill and re-clamp the pan.
            if !isPinching { applyZoom(PlayerZoomState.load()) }
        }
        .onChange(of: zoomFilled) { _, filled in fillToggle = filled }
        .onChange(of: fillToggle) { _, on in
            if on != zoomFilled { setZoomToFill(on) }
        }
        .onChange(of: holdingSide) { _, side in
            if let side {
                boostSide = side
                playerManager.beginSpeedBoost()
                // The 2x badge shows for 3s, then gets out of the way.
                showSpeedBadge = true
                speedBadgeTask?.cancel()
                speedBadgeTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard !Task.isCancelled else { return }
                    showSpeedBadge = false
                }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            } else if boostSide != nil {
                boostSide = nil
                lastHoldEnded = Date()
                playerManager.endSpeedBoost()
                speedBadgeTask?.cancel()
                showSpeedBadge = false
            }
        }
    }

    // MARK: Layers

    /// Full-bleed layer. In fullscreen it runs under the notch / Dynamic
    /// Island and home indicator, so there are no black bars beside them and
    /// a zoomed picture can use the whole screen.
    private var canvas: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                // Always aspect-fit; zoom is a transform so it can animate
                // and keep the content under the fingers.
                VideoPlayerLayer(player: playerManager.player, isFullscreen: isFullscreen, manager: playerManager)
                    .scaleEffect(zoomScale, anchor: .center)
                    .offset(zoomOffset)
                    .allowsHitTesting(false)

                scrims

                // Tap / double-tap / hold zones cover the whole screen, so
                // the areas beside the notch respond like the picture does.
                gestureZones(width: geo.size.width)

                seekFeedbackView(size: geo.size)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .background {
                // A window recognizer sees both fingers even when one lands on
                // a tap/hold zone and the other lands on a visible control.
                // It sits on the canvas so its coordinates match the video's.
                PlayerPinchCapture(isActive: isFullscreen || !playerManager.wantsFullscreen) { event in
                    handlePinch(event)
                }
                .allowsHitTesting(false)
            }
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { _, size in canvasSize = size }
        }
        .ignoresSafeArea(edges: isFullscreen ? Edge.Set.all : Edge.Set())
    }

    /// Controls, captions and badges, inside the safe area.
    private var foreground: some View {
        ZStack {
            CaptionOverlay(playerManager: playerManager, bottomInset: showControls ? (isFullscreen ? 96 : 76) : 16)
                .animation(spring, value: showControls)

            if playerManager.isLoading {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.4)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }

            if let error = playerManager.error {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.yellow)
                        .symbolEffect(.bounce, value: error)
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
                .transition(.opacity)
            }

            if !playerManager.isLoading && playerManager.error == nil {
                controls
                    .opacity(showControls ? 1 : 0)
                    .allowsHitTesting(showControls)
                    .accessibilityHidden(!showControls)
            }

            playPauseFlash

            topBadges

            skipIntroButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Scrims only; they never take touches. Full-bleed so the gradient
    /// reaches the physical top and bottom edges.
    private var scrims: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: isFullscreen ? 130 : 70)
            Spacer(minLength: 0)
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .frame(height: isFullscreen ? 160 : 90)
        }
        .opacity(showControls && !playerManager.isLoading && playerManager.error == nil ? 1 : 0)
        .allowsHitTesting(false)
    }

    // MARK: Gesture zones

    private func gestureZones(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            zone(.left).frame(width: width * 0.35)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { centerTap() }
            zone(.right).frame(width: width * 0.35)
        }
    }

    private func zone(_ side: Side) -> some View {
        Color.clear
            .contentShape(Rectangle())
            // One tap recogniser so a single tap responds instantly; a
            // second tap within 0.28s turns it into a double-tap seek.
            .onTapGesture { tap(side) }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.35)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .updating($holdingSide) { value, state, _ in
                        if case .second(true, _) = value { state = side }
                    }
            )
    }

    @State private var lastTap: (side: Side, time: Date, controlsBefore: Bool)?

    /// Middle of the picture: play / pause, and bring the controls up even
    /// when they were hidden.
    private func centerTap() {
        let wasPlaying = playerManager.isPlaying
        playerManager.togglePlayPause()
        reveal(autoHide: true)
        // A watch-party viewer without control can't toggle; no flash then.
        if playerManager.isPlaying != wasPlaying {
            flashPlayPause(playerManager.isPlaying ? "play.fill" : "pause.fill")
        }
    }

    private func tap(_ side: Side) {
        // A finished hold also ends as a tap; ignore it.
        guard Date().timeIntervalSince(lastHoldEnded) > 0.3 else { return }
        let now = Date()
        // While this side's seek ripple is showing, every tap on it keeps seeking.
        if rippleVisible(side) {
            doubleTap(side)
            lastTap = nil
            return
        }
        if let last = lastTap, last.side == side, now.timeIntervalSince(last.time) < 0.28 {
            // Undo the instant toggle from the first tap, then seek.
            showControls = last.controlsBefore
            lastTap = nil
            doubleTap(side)
            return
        }
        lastTap = (side, now, showControls)
        toggleControls()
    }

    private func doubleTap(_ side: Side) {
        let step = store.seekInterval
        if side == .left { playerManager.seekBackward(Double(step)) } else { playerManager.seekForward(Double(step)) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        var ripple = side == .left ? leftRipple : rightRipple
        if rippleVisible(side) {
            // Consecutive double-taps on the same side add up, YouTube-style.
            withAnimation(.spring(response: 0.36, dampingFraction: 0.75)) {
                ripple.seconds += step
                ripple.pulse += 1
                setRipple(ripple, side)
            }
        } else {
            // Swap content without animation, then fade/scale it in.
            ripple.seconds = step
            ripple.pulse += 1
            setRipple(ripple, side)
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { setRippleVisible(true, side) }
        }
        let fade = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.45)) { setRippleVisible(false, side) }
        }
        if side == .left {
            leftRippleTask?.cancel()
            leftRippleTask = fade
        } else {
            rightRippleTask?.cancel()
            rightRippleTask = fade
        }
    }

    private func rippleVisible(_ side: Side) -> Bool {
        side == .left ? leftRippleVisible : rightRippleVisible
    }

    private func setRippleVisible(_ visible: Bool, _ side: Side) {
        if side == .left { leftRippleVisible = visible } else { rightRippleVisible = visible }
    }

    private func setRipple(_ ripple: SeekRipple, _ side: Side) {
        if side == .left { leftRipple = ripple } else { rightRipple = ripple }
    }

    // MARK: Feedback views

    private func seekFeedbackView(size: CGSize) -> some View {
        ZStack {
            seekLayer(.left, ripple: leftRipple, visible: leftRippleVisible, size: size)
            seekLayer(.right, ripple: rightRipple, visible: rightRippleVisible, size: size)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    /// One side's ripple. Pinned to its own edge; only its opacity and the
    /// label's scale animate, so it can never slide toward the other side.
    private func seekLayer(_ side: Side, ripple: SeekRipple, visible: Bool, size: CGSize) -> some View {
        let isLeft = side == .left
        return ZStack {
            // Start the glow at the physical edge, then fade it into the
            // picture. An ellipse left transparent gaps at the corners.
            LinearGradient(
                colors: isLeft ? [.white.opacity(0.17), .white.opacity(0.07), .clear] : [.clear, .white.opacity(0.07), .white.opacity(0.17)],
                startPoint: .leading, endPoint: .trailing
            )

            VStack(spacing: 6) {
                Image(systemName: isLeft ? "backward.fill" : "forward.fill")
                    .font(.system(size: isFullscreen ? 30 : 22, weight: .semibold))
                    .symbolEffect(.bounce, value: ripple.pulse)
                Text("\(ripple.seconds) seconds")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText())
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.4), radius: 6)
            .scaleEffect(visible ? 1 : 0.85)
            // Label sits about 18% of the width in from its edge.
            .offset(x: isLeft ? -size.width * 0.05 : size.width * 0.05)
        }
        .frame(width: size.width * 0.46, height: size.height)
        .frame(width: size.width, height: size.height, alignment: isLeft ? .leading : .trailing)
        // Always in the tree; opacity drives in and out so the fade-out
        // can't be skipped by a view removal.
        .opacity(visible ? 1 : 0)
        .accessibilityHidden(!visible)
    }

    /// Brief glass flash in the middle after a center tap.
    @ViewBuilder private var playPauseFlash: some View {
        if let flash = playFlash {
            Image(systemName: flash.icon)
                .font(.system(size: isFullscreen ? 32 : 25, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: isFullscreen ? 76 : 60, height: isFullscreen ? 76 : 60)
                .vixGlass(.regular, cornerRadius: 999)
                .id(flash.id)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.75).combined(with: .opacity),
                    removal: .scale(scale: 1.3).combined(with: .opacity)
                ))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func flashPlayPause(_ icon: String) {
        playFlashTask?.cancel()
        let id = (playFlash?.id ?? 0) + 1
        withAnimation(.easeOut(duration: 0.12)) { playFlash = PlayFlash(icon: icon, id: id) }
        playFlashTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.23)) { playFlash = nil }
        }
    }

    /// The 2× speed badge and the zoom indicator share the top-center slot.
    private var topBadges: some View {
        VStack {
            HStack(spacing: 8) {
                if playerManager.isSpeedBoosted && showSpeedBadge {
                    HStack(spacing: 6) {
                        Text("2×")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                        Image(systemName: "forward.fill")
                            .font(.caption.weight(.bold))
                            .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: true)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .vixGlass(.strong, cornerRadius: 999)
                    .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.8)))
                }
                if let zoomBadge {
                    Text(zoomBadge)
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .contentTransition(.numericText())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .vixGlass(.strong, cornerRadius: 999)
                        .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.8)))
                        .accessibilityLabel("Zoom \(zoomBadge)")
                }
            }
            .padding(.top, isFullscreen ? 24 : 12)
            Spacer()
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: playerManager.isSpeedBoosted && showSpeedBadge)
        .allowsHitTesting(false)
    }

    // MARK: Zoom

    private var currentFillScale: CGFloat {
        PlayerZoomMath.fillScale(video: videoSize, canvas: canvasSize)
    }

    private func handlePinch(_ event: PlayerPinchEvent) {
        switch event.state {
        case .began:
            isPinching = true
            zoomRaw = zoomScale
            pinchAnchor = event.location
            pinchTouches = event.touches
            zoomBadgeTask?.cancel()
            showZoomBadge(scaleLabel(zoomScale), autoHide: false)
        case .changed:
            guard isPinching else { return }
            let canvas = event.size.width > 0 ? event.size : canvasSize
            let upper = PlayerZoomMath.upperLimit(fill: PlayerZoomMath.fillScale(video: videoSize, canvas: canvas))
            let oldScale = max(zoomScale, PlayerZoomMath.minScale)
            zoomRaw = PlayerZoomMath.clampRaw(zoomRaw * event.scaleDelta, upper: upper)
            let newScale = PlayerZoomMath.displayed(raw: zoomRaw, upper: upper)
            // A finger lifting or landing moves the centroid; re-anchor
            // instead of treating that jump as a pan.
            let previous = event.touches == pinchTouches ? (pinchAnchor ?? event.location) : event.location
            let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            // The content point under the previous centroid stays under the
            // current one, which also pans with two fingers.
            let contentX = (previous.x - center.x - zoomOffset.width) / oldScale
            let contentY = (previous.y - center.y - zoomOffset.height) / oldScale
            let proposed = CGSize(width: event.location.x - center.x - newScale * contentX,
                                  height: event.location.y - center.y - newScale * contentY)
            zoomScale = newScale
            zoomOffset = PlayerZoomMath.clampedOffset(proposed, scale: newScale, video: videoSize, canvas: canvas)
            zoomFilled = false
            pinchAnchor = event.location
            pinchTouches = event.touches
            showZoomBadge(scaleLabel(newScale), autoHide: false)
        case .ended, .cancelled, .failed:
            guard isPinching else { return }
            isPinching = false
            pinchAnchor = nil
            settleZoom()
        default:
            break
        }
    }

    /// Release: spring into range, or snap to fill / the original frame.
    private func settleZoom() {
        let fill = currentFillScale
        let upper = PlayerZoomMath.upperLimit(fill: fill)
        let shown = zoomScale
        let tolerance = PlayerZoomMath.snapTolerance
        let canFill = fill > 1.01
        let nearFill = canFill && abs(shown - fill) <= fill * tolerance
        let nearOne = abs(shown - 1) <= tolerance

        var target = shown
        var filled = false
        var label = scaleLabel(shown)
        var snapped = false
        if shown < 1 {
            target = 1
            label = "Original"
        } else if shown > upper {
            target = upper
            filled = canFill && abs(upper - fill) < 0.001
            label = filled ? "Zoomed to fill" : scaleLabel(upper)
        } else if nearFill && (!nearOne || abs(shown - fill) < abs(shown - 1)) {
            target = fill
            filled = true
            label = "Zoomed to fill"
            snapped = true
        } else if nearOne {
            target = 1
            label = "Original"
            snapped = true
        }

        // Scaling about the center keeps the same spot in view.
        let ratio = shown > 0 ? target / shown : 1
        let offset = PlayerZoomMath.clampedOffset(
            CGSize(width: zoomOffset.width * ratio, height: zoomOffset.height * ratio),
            scale: target, video: videoSize, canvas: canvasSize)
        withAnimation(zoomSpring) {
            zoomScale = target
            zoomOffset = offset
            zoomFilled = filled
        }
        zoomRaw = target
        if snapped { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        showZoomBadge(label)
        saveZoom()
    }

    /// Settings › Zoom to Fill.
    private func setZoomToFill(_ on: Bool) {
        let target: CGFloat = on ? currentFillScale : 1
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            zoomScale = target
            zoomOffset = .zero
            zoomFilled = on
        }
        zoomRaw = target
        showZoomBadge(on ? "Zoomed to fill" : "Original")
        saveZoom()
    }

    /// Applies a stored zoom to the current canvas and picture. A filled
    /// zoom is recomputed, since the fill scale depends on both sizes.
    private func applyZoom(_ state: PlayerZoomState) {
        let fill = currentFillScale
        let upper = PlayerZoomMath.upperLimit(fill: fill)
        let scale = state.filled ? fill : min(max(state.scale, 1), upper)
        let pan = CGSize(width: state.panX * canvasSize.width, height: state.panY * canvasSize.height)
        zoomScale = scale
        zoomRaw = scale
        zoomFilled = state.filled
        zoomOffset = PlayerZoomMath.clampedOffset(pan, scale: scale, video: videoSize, canvas: canvasSize)
    }

    private func saveZoom() {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        PlayerZoomState(scale: zoomScale,
                        panX: zoomOffset.width / canvasSize.width,
                        panY: zoomOffset.height / canvasSize.height,
                        filled: zoomFilled).save()
    }

    private func scaleLabel(_ scale: CGFloat) -> String {
        String(format: "%.1f×", Double(scale))
    }

    private func showZoomBadge(_ text: String, autoHide: Bool = true) {
        zoomBadgeTask?.cancel()
        if zoomBadge == nil {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) { zoomBadge = text }
        } else if zoomBadge != text {
            // Live pinch updates change every frame; only snaps animate.
            if autoHide {
                withAnimation(.snappy(duration: 0.2)) { zoomBadge = text }
            } else {
                zoomBadge = text
            }
        }
        guard autoHide else { return }
        zoomBadgeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { zoomBadge = nil }
        }
    }

    /// Polls the item's presentation size on the main actor. KVO on the
    /// player item could call back off the main thread.
    private func watchVideoSize() async {
        var lastItem: ObjectIdentifier?
        var first = true
        while !Task.isCancelled {
            let item = playerManager.player?.currentItem
            let id = item.map { ObjectIdentifier($0) }
            let size = item?.presentationSize ?? .zero
            if first || id != lastItem {
                // New item: reapply where the viewer left the zoom.
                first = false
                lastItem = id
                videoSize = size
                if !isPinching { applyZoom(PlayerZoomState.load()) }
            } else if size.width > 0, size.height > 0, size != videoSize {
                videoSize = size
                if !isPinching { applyZoom(PlayerZoomState.load()) }
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            transport
                .offset(x: !isFullscreen && hasNextEpisodeVisible && playerManager.activeSkipSegment != nil ? -60 : 0)
            Spacer(minLength: 0)
            nextEpisodePill
            PlayerScrubber(playerManager: playerManager, isFullscreen: isFullscreen) {
                reveal(autoHide: false)
            } onEnd: {
                scheduleHide()
            }
        }
        .padding(.horizontal, isFullscreen ? 20 : 14)
        .padding(.top, isFullscreen ? 14 : 10)
        .padding(.bottom, isFullscreen ? 6 : 8)
    }

    /// One action at a time, including adjacent recap → intro transitions.
    /// the controls auto-hide; hidden for watch-party viewers who can't
    /// control playback (the host's skip moves them anyway).
    @ViewBuilder private var skipIntroButton: some View {
        let party = PartySession.shared
        if let segment = playerManager.activeSkipSegment,
           (segment.kind == .intro || segment.kind == .recap || showControls),
           !playerManager.isLoading, playerManager.error == nil,
           !(party.active && !party.canControl) {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        playerManager.skipIntro()
                        reveal(autoHide: true)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "forward.fill")
                            Text("Skip \(segment.kind.rawValue.capitalized)").lineLimit(1)
                        }
                        .id(segment.kind)
                        .transition(.asymmetric(
                            insertion: .offset(y: 10).combined(with: .opacity).combined(with: .scale(scale: 0.94)),
                            removal: .offset(y: -9).combined(with: .opacity)
                        ))
                        .font((isFullscreen ? Font.subheadline : Font.footnote).weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, isFullscreen ? 18 : 14)
                        .padding(.vertical, isFullscreen ? 11 : 8)
                        .background(segment.kind == .intro || segment.kind == .recap ? Color.white : Color.white.opacity(0.68), in: Capsule())
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                    }
                    .buttonStyle(PlayerButtonStyle())
                    .accessibilityLabel("Skip \(segment.kind.rawValue)")
                }
            }
            .padding(.horizontal, isFullscreen ? 20 : 14)
            .padding(.bottom, showControls ? (isFullscreen ? (hasNextEpisodeVisible ? 124 : 82) : (hasNextEpisodeVisible ? 95 : 56)) : (isFullscreen ? 14 : 12))
            .animation(spring, value: showControls)
            .animation(.spring(response: 0.42, dampingFraction: 0.78), value: segment.kind)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    /// In the last five minutes of an episode, a Next Episode button sits above
    /// the timeline whenever the controls are visible.
    @ViewBuilder private var nextEpisodePill: some View {
        let remaining = playerManager.duration - playerManager.currentTime
        if let label = options.nextEpisodeLabel, let action = options.onNextEpisode,
           hasNextEpisodeVisible, remaining <= 300 {
            HStack {
                Spacer()
                Button(action: action) {
                    HStack(spacing: 8) {
                        Image(systemName: "forward.end.fill")
                        Text(label).lineLimit(1)
                    }
                    .font((isFullscreen ? Font.subheadline : Font.footnote).weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, isFullscreen ? 18 : 14)
                    .padding(.vertical, isFullscreen ? 11 : 8)
                    .background(.white, in: Capsule())
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                }
                .buttonStyle(PlayerButtonStyle())
                .accessibilityLabel("Play next episode, \(label)")
            }
            .padding(.bottom, 4)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    // MARK: Top bar

    /// Left to right: PiP, Rotate, Captions, Settings, fullscreen.
    private var topBar: some View {
        let size: CGFloat = isFullscreen ? 44 : 36
        return HStack(spacing: 10) {
            if isFullscreen {
                Text(playerManager.nowPlayingDisplayTitle)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.4), radius: 4)
            }
            Spacer()

            if AVPictureInPictureController.isPictureInPictureSupported() {
                GlassIconButton(systemImage: "pip.enter", size: size, label: "Picture in Picture") {
                    playerManager.startPictureInPicture()
                }
            }

            GlassIconButton(systemImage: rotateClockwise ? "rotate.right" : "rotate.left", size: size, label: "Rotate") {
                rotateInterface()
            }

            GlassIconButton(systemImage: captionsOn ? "captions.bubble.fill" : "captions.bubble",
                            size: size,
                            label: captionsOn ? "Turn captions off" : "Turn captions on",
                            isHighlighted: captionsOn) {
                toggleCaptions()
                reveal(autoHide: true)
            }
            .disabled(!playerManager.hasAnySubtitles)
            .opacity(playerManager.hasAnySubtitles ? 1 : 0.4)

            settingsMenu

            GlassIconButton(systemImage: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                            size: size,
                            label: isFullscreen ? "Exit full screen" : "Full screen") {
                onToggleFullscreen()
            }
        }
    }

    /// Fullscreen: portrait ↔ landscape in the chosen direction. Works with
    /// the rotation lock on. Inline it enters fullscreen, which rotates too.
    private func rotateInterface() {
        reveal(autoHide: true)
        guard isFullscreen else {
            onToggleFullscreen()
            return
        }
        if OrientationLock.isPortrait {
            OrientationLock.rotate(to: rotateClockwise ? .landscapeRight : .landscapeLeft)
        } else {
            OrientationLock.rotate(to: .portrait)
        }
    }

    private var settingsMenu: some View {
        Menu {
            if options.sources.count > 1 {
                Menu {
                    let sections = options.sources.reduce(into: [String]()) { if !$0.contains($1.section) { $0.append($1.section) } }
                    ForEach(sections, id: \.self) { section in
                        Section(section) {
                            ForEach(options.sources.filter { $0.section == section }) { choice in
                                Button {
                                    options.onSelectSource(choice.id)
                                    reveal(autoHide: true)
                                } label: {
                                    if choice.id == options.selectedSource {
                                        Label(choice.title, systemImage: "checkmark")
                                    } else {
                                        Text(choice.title)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    menuLabel(options.sourceLabel,
                              value: options.sources.first(where: { $0.id == options.selectedSource })?.title,
                              systemImage: "slider.horizontal.3")
                }
            }

            if options.servers.count > 1 {
                Menu {
                    ForEach(Array(options.servers.enumerated()), id: \.offset) { index, name in
                        Button {
                            options.onSelectServer(index)
                        } label: {
                            if index == options.selectedServer {
                                Label(name, systemImage: "checkmark")
                            } else {
                                Text(name)
                            }
                        }
                    }
                } label: {
                    menuLabel("Server",
                              value: options.servers.indices.contains(options.selectedServer) ? options.servers[options.selectedServer] : nil,
                              systemImage: "server.rack")
                }
            }

            Section {
                Menu {
                    captionTrackItems
                } label: {
                    menuLabel("Captions", value: captionValue, systemImage: "captions.bubble")
                }
                .disabled(!playerManager.hasAnySubtitles)

                Button {
                    openCaptionStyleSettings()
                } label: {
                    Label("Caption Size & Style", systemImage: "textformat.size")
                }
            }

            Section {
                Toggle(isOn: $fillToggle) {
                    Label("Zoom to Fill", systemImage: "arrow.up.left.and.arrow.down.right")
                }

                Menu {
                    Button {
                        rotateClockwise = true
                    } label: {
                        if rotateClockwise {
                            Label("Clockwise", systemImage: "checkmark")
                        } else {
                            Label("Clockwise", systemImage: "rotate.right")
                        }
                    }
                    Button {
                        rotateClockwise = false
                    } label: {
                        if !rotateClockwise {
                            Label("Counterclockwise", systemImage: "checkmark")
                        } else {
                            Label("Counterclockwise", systemImage: "rotate.left")
                        }
                    }
                } label: {
                    menuLabel("Rotate Direction",
                              value: rotateClockwise ? "Clockwise" : "Counterclockwise",
                              systemImage: rotateClockwise ? "rotate.right" : "rotate.left")
                }
            }
        } label: {
            GlassIcon(systemImage: "gearshape", size: isFullscreen ? 44 : 36)
        }
        .accessibilityLabel("Settings")
        .simultaneousGesture(TapGesture().onEnded { reveal(autoHide: false) })
    }

    /// Menu row with the current value as its subtitle, Apple style.
    private func menuLabel(_ title: String, value: String?, systemImage: String) -> some View {
        Label {
            Text(title)
            if let value { Text(value) }
        } icon: {
            Image(systemName: systemImage)
        }
    }

    // MARK: Captions

    /// Full track picker: Off, auto-generated, embedded and side-loaded.
    @ViewBuilder private var captionTrackItems: some View {
        Section {
            Button {
                playerManager.selectSubtitle(at: nil)
                playerManager.selectExternalSubtitle(at: nil)
            } label: {
                if !captionsOn { Label("Off", systemImage: "checkmark") } else { Text("Off") }
            }
        }
        // Top-level section: nesting it inside the track list made the
        // choices disappear from the menu on iOS.
        Section("Auto-generated") {
            if playerManager.canGenerateCaptions {
                if playerManager.spokenAudioLanguage != "ja" {
                    Button {
                        startGeneratedCaptions(locale: "en-US", translated: false)
                    } label: {
                        if playerManager.generatedCaptionLocale == "en-US" {
                            Label("English", systemImage: "checkmark")
                        } else { Text("English") }
                    }
                }
                if options.isAnime && playerManager.spokenAudioLanguage != "en" {
                    Button {
                        startGeneratedCaptions(locale: "ja-JP", translated: false)
                    } label: {
                        if playerManager.generatedCaptionLocale == "ja-JP" && !playerManager.translateGeneratedCaptions {
                            Label("Japanese", systemImage: "checkmark")
                        } else { Text("Japanese") }
                    }
                    Button {
                        startGeneratedCaptions(locale: "ja-JP", translated: true)
                    } label: {
                        if playerManager.generatedCaptionLocale == "ja-JP" && playerManager.translateGeneratedCaptions {
                            Label("Japanese → English", systemImage: "checkmark")
                        } else { Text("Japanese → English") }
                    }
                }
            } else {
                Button {} label: {
                    Text(playerManager.generatedCaptionsUnavailableReason ?? "Auto-generated captions are unavailable on this device.")
                }
                .disabled(true)
            }
        }
        if !playerManager.subtitleOptions.isEmpty {
            Section("This video") {
                ForEach(Array(playerManager.subtitleOptions.enumerated()), id: \.offset) { index, option in
                    Button {
                        playerManager.selectSubtitle(at: index)
                    } label: {
                        if playerManager.selectedSubtitleIndex == index {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Text(option.displayName)
                        }
                    }
                }
            }
        }
        if !playerManager.externalSubtitles.isEmpty {
            Section("Side-loaded") {
                ForEach(Array(playerManager.externalSubtitles.enumerated()), id: \.offset) { index, track in
                    Button {
                        playerManager.selectExternalSubtitle(at: index)
                    } label: {
                        if playerManager.selectedExternalSubtitleIndex == index {
                            Label(track.label, systemImage: "checkmark")
                        } else {
                            Text(track.label)
                        }
                    }
                }
            }
        }
    }

    /// Current caption choice for the Settings menu subtitle.
    private var captionValue: String {
        if let locale = playerManager.generatedCaptionLocale {
            if locale == "ja-JP" {
                return playerManager.translateGeneratedCaptions ? "Japanese → English (Auto)" : "Japanese (Auto)"
            }
            return "English (Auto)"
        }
        if let index = playerManager.selectedSubtitleIndex, playerManager.subtitleOptions.indices.contains(index) {
            return playerManager.subtitleOptions[index].displayName
        }
        if let index = playerManager.selectedExternalSubtitleIndex, playerManager.externalSubtitles.indices.contains(index) {
            return playerManager.externalSubtitles[index].label
        }
        return "Off"
    }

    /// Stable description of the active caption, or nil when captions are off.
    private var captionChoiceKey: String? {
        if let locale = playerManager.generatedCaptionLocale {
            return "generated:" + (playerManager.translateGeneratedCaptions ? "ja-JP->en" : locale)
        }
        if let index = playerManager.selectedSubtitleIndex, playerManager.subtitleOptions.indices.contains(index) {
            return "embedded:" + playerManager.subtitleOptions[index].displayName
        }
        if let index = playerManager.selectedExternalSubtitleIndex, playerManager.externalSubtitles.indices.contains(index) {
            return "external:" + playerManager.externalSubtitles[index].label
        }
        return nil
    }

    /// Remembers the last caption that was on, for the captions toggle.
    private func rememberCaptionChoice(_ key: String?) {
        guard let key else { return }
        UserDefaults.standard.set(key, forKey: Self.lastCaptionKey)
    }

    private func toggleCaptions() {
        if captionsOn {
            // Same as the menu's Off: also stops generated captions.
            playerManager.selectSubtitle(at: nil)
            playerManager.selectExternalSubtitle(at: nil)
        } else {
            turnCaptionsOn()
        }
    }

    /// Last choice, else English, else the first track, else generated English.
    private func turnCaptionsOn() {
        let manager = playerManager
        if let last = UserDefaults.standard.string(forKey: Self.lastCaptionKey) {
            if last.hasPrefix("embedded:") {
                let name = String(last.dropFirst("embedded:".count))
                if let index = manager.subtitleOptions.firstIndex(where: { $0.displayName == name }) {
                    manager.selectSubtitle(at: index)
                    return
                }
            } else if last.hasPrefix("external:") {
                let label = String(last.dropFirst("external:".count))
                if let index = manager.externalSubtitles.firstIndex(where: { $0.label == label }) {
                    manager.selectExternalSubtitle(at: index)
                    return
                }
            } else if last.hasPrefix("generated:"), manager.canGenerateCaptions {
                let locale = String(last.dropFirst("generated:".count))
                let translated = locale == "ja-JP->en"
                // Japanese generated captions are only offered for anime.
                if !locale.hasPrefix("ja") || options.isAnime {
                    startGeneratedCaptions(locale: translated ? "ja-JP" : locale, translated: translated)
                    return
                }
            }
        }
        if let index = manager.subtitleOptions.firstIndex(where: { isEnglish($0) }) {
            manager.selectSubtitle(at: index)
        } else if let index = manager.externalSubtitles.firstIndex(where: { $0.label.lowercased().contains("english") }) {
            manager.selectExternalSubtitle(at: index)
        } else if !manager.subtitleOptions.isEmpty {
            manager.selectSubtitle(at: 0)
        } else if !manager.externalSubtitles.isEmpty {
            manager.selectExternalSubtitle(at: 0)
        } else if manager.canGenerateCaptions {
            startGeneratedCaptions(locale: "en-US", translated: false)
        }
    }

    private func isEnglish(_ option: AVMediaSelectionOption) -> Bool {
        if let tag = option.extendedLanguageTag?.lowercased(), tag == "en" || tag.hasPrefix("en-") { return true }
        if option.locale?.language.languageCode?.identifier.lowercased() == "en" { return true }
        return option.displayName.lowercased().contains("english")
    }

    private func startGeneratedCaptions(locale: String, translated: Bool) {
        Task {
            await playerManager.selectGeneratedCaptions(locale: locale, translated: translated)
            showGeneratedCaptionError = playerManager.generatedCaptionError != nil
        }
    }

    /// Opens Settings › Accessibility › Subtitles & Captioning. The private
    /// URL is acceptable for this sideloaded build; when iOS refuses it, the
    /// app's own Settings page opens instead.
    private func openCaptionStyleSettings() {
        Task { @MainActor in
            if let url = URL(string: "App-prefs:ACCESSIBILITY&path=SUBTITLES_CAPTIONING") {
                let opened = await UIApplication.shared.open(url, options: [:])
                if opened { return }
            }
            if let url = URL(string: UIApplication.openSettingsURLString) {
                let _: Bool = await UIApplication.shared.open(url, options: [:])
            }
        }
    }

    private var transport: some View {
        let step = store.seekInterval
        return HStack(spacing: isFullscreen ? 56 : 36) {
            SkipButton(forward: false, seconds: step, size: isFullscreen ? 30 : 24) {
                playerManager.seekBackward(Double(step))
                reveal(autoHide: true)
            }
            PlayPauseButton(isPlaying: playerManager.isPlaying, size: isFullscreen ? 76 : 60) {
                playerManager.togglePlayPause()
                reveal(autoHide: true)
            }
            SkipButton(forward: true, seconds: step, size: isFullscreen ? 30 : 24) {
                playerManager.seekForward(Double(step))
                reveal(autoHide: true)
            }
        }
    }

    // MARK: Visibility

    private func toggleControls() {
        if showControls {
            hideTask?.cancel()
            showControls = false
        } else {
            reveal(autoHide: true)
        }
    }

    private func reveal(autoHide: Bool) {
        showControls = true
        if autoHide { scheduleHide() } else { hideTask?.cancel() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled, playerManager.isPlaying else { return }
            showControls = false
        }
    }
}

@available(iOS 18.0, *)
private struct CaptionTranslationBridge: View {
    @Bindable var playerManager: VideoPlayerManager
    let active: Bool
    @State private var configuration = TranslationSession.Configuration(
        source: Locale.Language(identifier: "ja"),
        target: Locale.Language(identifier: "en")
    )

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .translationTask(active ? configuration : nil) { session in
                await CaptionTranslationDriver.run(session: .init(value: session), manager: playerManager)
            }
    }
}

@available(iOS 18.0, *)
private enum CaptionTranslationDriver {
    // SwiftUI owns this non-Sendable session for the lifetime of its task.
    // The driver uses it serially and stops when SwiftUI cancels that task.
    struct Session: @unchecked Sendable { let value: TranslationSession }

    static func run(session: Session, manager: VideoPlayerManager) async {
        do {
            try await session.value.prepareTranslation()
            while !Task.isCancelled {
                if let cue = await manager.nextCaptionToTranslate() {
                    let result = try await session.value.translate(cue.text)
                    await manager.acceptTranslatedCaption(cue, text: result.targetText)
                } else {
                    try await Task.sleep(for: .milliseconds(400))
                }
            }
        } catch is CancellationError {
            return
        } catch {
            await manager.setCaptionTranslationError(error)
        }
    }
}

// MARK: - Controls

/// Play / pause in a glass disc; the symbol morphs between states.
private struct PlayPauseButton: View {
    let isPlaying: Bool
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.42, weight: .semibold))
                // Quick down-up swap with a small bounce, so the state change
                // reads instantly without a slow crossfade.
                .contentTransition(.symbolEffect(.replace.downUp))
                .symbolEffect(.bounce.down, options: .speed(1.6), value: isPlaying)
                .animation(.spring(response: 0.2, dampingFraction: 0.82), value: isPlaying)
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .vixGlass(.regular, cornerRadius: 999)
        }
        .buttonStyle(PlayerButtonStyle())
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}

/// Skip back / forward. Spins a little and bounces on every tap.
private struct SkipButton: View {
    let forward: Bool
    let seconds: Int
    let size: CGFloat
    let action: () -> Void
    @State private var angle: Double = 0
    @State private var pop = false

    var body: some View {
        Button {
            // A full turn in the skip direction with a quick pop.
            withAnimation(.spring(response: 0.84, dampingFraction: 0.72)) {
                angle += forward ? 360 : -360
            }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.5)) { pop = true }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 280_000_000)
                withAnimation(.spring(response: 0.6, dampingFraction: 0.55)) { pop = false }
            }
            action()
        } label: {
            Image(systemName: forward ? "goforward.\(seconds)" : "gobackward.\(seconds)")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(angle))
                .scaleEffect(pop ? 1.22 : 1)
                .frame(width: size * 1.9, height: size * 1.9)
                .contentShape(Circle())
        }
        .buttonStyle(PlayerButtonStyle())
        .accessibilityLabel(forward ? "Skip forward \(seconds) seconds" : "Skip back \(seconds) seconds")
    }
}

/// Extra controls a screen can hand the player: quality / audio, server,
/// and a next-episode action. Everything is optional.
struct PlayerOptions {
    struct Choice: Identifiable {
        let id: Int
        let title: String
        /// Menu group, e.g. "Subtitled" / "Dubbed", or "Source".
        let section: String
    }

    var sources: [Choice] = []
    var selectedSource = 0
    var sourceLabel = "Quality"
    var onSelectSource: (Int) -> Void = { _ in }

    var servers: [String] = []
    var selectedServer = 0
    var onSelectServer: (Int) -> Void = { _ in }

    var nextEpisodeLabel: String?
    var onNextEpisode: (() -> Void)?

    /// Japanese generated captions (and their English translation) are only
    /// offered for anime.
    var isAnime = false
}

/// Glass disc icon, used as a Menu label in the top bar.
private struct GlassIcon: View {
    let systemImage: String
    let size: CGFloat

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .vixGlass(.regular, cornerRadius: 999)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// Small round glass button used in the top bar.
private struct GlassIconButton: View {
    let systemImage: String
    let size: CGFloat
    let label: String
    /// On-state for toggles (captions): a brighter disc behind the glyph.
    var isHighlighted = false
    let action: () -> Void
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: taps)
                .frame(width: size, height: size)
                .background(Circle().fill(.white.opacity(isHighlighted ? 0.26 : 0)))
                .vixGlass(.regular, cornerRadius: 999)
                .animation(.easeOut(duration: 0.2), value: isHighlighted)
        }
        .buttonStyle(PlayerButtonStyle())
        .accessibilityLabel(label)
    }
}

/// Timeline. Thickens and shows a larger thumb while scrubbing.
private struct PlayerScrubber: View {
    @Bindable var playerManager: VideoPlayerManager
    let isFullscreen: Bool
    let onBegin: () -> Void
    let onEnd: () -> Void
    @State private var isSeeking = false
    @State private var seekPosition: Double = 0

    var body: some View {
        let duration = playerManager.duration
        let shown = isSeeking ? seekPosition : playerManager.currentTime
        VStack(spacing: 4) {
            GeometryReader { geo in
                let width = max(1, geo.size.width)
                let fraction = duration > 0 ? min(1, max(0, shown / duration)) : 0
                let barHeight: CGFloat = isSeeking ? 8 : 4
                let thumb: CGFloat = isSeeking ? 18 : 12
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25)).frame(height: barHeight)
                    Capsule().fill(.white).frame(width: width * fraction, height: barHeight)
                    Circle()
                        .fill(.white)
                        .frame(width: thumb, height: thumb)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .offset(x: min(max(0, width - thumb), width * fraction - thumb / 2))
                }
                .frame(width: width, height: 28)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }
                            if !isSeeking {
                                isSeeking = true
                                onBegin()
                                UISelectionFeedbackGenerator().selectionChanged()
                            }
                            seekPosition = min(1, max(0, value.location.x / width)) * duration
                        }
                        .onEnded { value in
                            guard duration > 0 else { return }
                            playerManager.seek(to: min(1, max(0, value.location.x / width)) * duration)
                            isSeeking = false
                            onEnd()
                        }
                )
                .animation(.spring(response: 0.15, dampingFraction: 0.85), value: isSeeking)
            }
            .frame(height: 28)

            HStack {
                Text(format(shown))
                Spacer()
                Text("-" + format(max(0, duration - shown)))
            }
            .font((isFullscreen ? Font.footnote : Font.caption2).monospacedDigit().weight(.medium))
            .foregroundStyle(.white.opacity(0.85))
            .contentTransition(.numericText())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(format(shown)) of \(format(duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: playerManager.seekForward(10)
            case .decrement: playerManager.seekBackward(10)
            @unknown default: break
            }
        }
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Pinch recognition belongs to the window, so the player's separate tap and
/// hold zones cannot swallow one of the two fingers. It only begins when both
/// touches are inside this player surface.
private struct PlayerPinchCapture: UIViewRepresentable {
    let isActive: Bool
    let onPinch: (PlayerPinchEvent) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.coordinator = context.coordinator
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: AttachmentView, context: Context) {
        context.coordinator.isActive = isActive
        context.coordinator.onPinch = onPinch
        context.coordinator.attach(to: view.window)
    }

    static func dismantleUIView(_ view: AttachmentView, coordinator: Coordinator) {
        coordinator.attach(to: nil)
        view.coordinator = nil
    }

    final class AttachmentView: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attach(to: window)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var view: UIView?
        private weak var attachedWindow: UIWindow?
        var isActive = true
        var onPinch: ((PlayerPinchEvent) -> Void)?
        private lazy var recognizer: UIPinchGestureRecognizer = {
            let gesture = UIPinchGestureRecognizer(target: self, action: #selector(handle(_:)))
            gesture.cancelsTouchesInView = false
            gesture.delegate = self
            return gesture
        }()

        func attach(to window: UIWindow?) {
            guard attachedWindow !== window else { return }
            attachedWindow?.removeGestureRecognizer(recognizer)
            attachedWindow = window
            window?.addGestureRecognizer(recognizer)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard isActive, let view, view.window != nil, gestureRecognizer.numberOfTouches >= 2 else { return false }
            return view.bounds.contains(gestureRecognizer.location(ofTouch: 0, in: view)) &&
                view.bounds.contains(gestureRecognizer.location(ofTouch: 1, in: view))
        }

        /// Reports the scale change since the last event and resets the
        /// recognizer to 1, so the player can re-anchor when the centroid
        /// jumps (a finger lifting) without a scale jump. The scale already
        /// gathered before `.began` is dropped so zoom starts smoothly.
        @objc private func handle(_ gesture: UIPinchGestureRecognizer) {
            guard let view else { return }
            let delta: CGFloat = gesture.state == .changed ? gesture.scale : 1
            gesture.scale = 1
            onPinch?(PlayerPinchEvent(state: gesture.state,
                                      scaleDelta: delta,
                                      location: gesture.location(in: view),
                                      size: view.bounds.size,
                                      touches: gesture.numberOfTouches))
        }
    }
}

/// UIViewRepresentable wrapper for AVPlayerLayer
struct VideoPlayerLayer: UIViewRepresentable {
    let player: AVPlayer?
    let isFullscreen: Bool
    var fillsFrame: Bool = false
    var manager: VideoPlayerManager? = nil
    
    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView(player: player, isFullscreen: isFullscreen, fillsFrame: fillsFrame)
        view.manager = manager
        view.attachPictureInPicture()
        return view
    }
    
    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.manager = manager
        uiView.isFullscreen = isFullscreen
        uiView.fillsFrame = fillsFrame
        uiView.player = player
    }

    static func dismantleUIView(_ uiView: PlayerUIView, coordinator: ()) {
        uiView.removeBackgroundObserver()
    }
    
    final class PlayerUIView: UIView {
        private var playerLayer: AVPlayerLayer?
        private var pictureInPictureController: AVPictureInPictureController?
        private var backgroundObserver: NSObjectProtocol?
        var isFullscreen: Bool
        var fillsFrame: Bool {
            didSet { playerLayer?.videoGravity = fillsFrame ? .resizeAspectFill : .resizeAspect }
        }
        
        var player: AVPlayer? {
            didSet {
                if player !== oldValue {
                    setupPlayerLayer()
                }
            }
        }
        
        init(player: AVPlayer?, isFullscreen: Bool, fillsFrame: Bool) {
            self.player = player
            self.isFullscreen = isFullscreen
            self.fillsFrame = fillsFrame
            super.init(frame: .zero)
            setupPlayerLayer()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        private func setupPlayerLayer() {
            if let backgroundObserver {
                NotificationCenter.default.removeObserver(backgroundObserver)
                self.backgroundObserver = nil
            }
            pictureInPictureController = nil
            playerLayer?.removeFromSuperlayer()
            playerLayer = nil
            
            guard let player else { return }
            
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = fillsFrame ? .resizeAspectFill : .resizeAspect
            layer.frame = bounds
            self.layer.addSublayer(layer)
            self.playerLayer = layer
            attachPictureInPicture()
        }

        weak var manager: VideoPlayerManager?

        /// Manual Picture in Picture only (the PiP button). It never starts
        /// by itself when leaving the app.
        func attachPictureInPicture() {
            guard let playerLayer, AVPictureInPictureController.isPictureInPictureSupported() else { return }
            if pictureInPictureController?.playerLayer !== playerLayer {
                let controller = AVPictureInPictureController(playerLayer: playerLayer)
                controller?.canStartPictureInPictureAutomaticallyFromInline = false
                pictureInPictureController = controller
            }
            if let controller = pictureInPictureController { manager?.attach(pictureInPicture: controller) }
        }

        func removeBackgroundObserver() {
            if let backgroundObserver {
                NotificationCenter.default.removeObserver(backgroundObserver)
                self.backgroundObserver = nil
            }
        }
        
        override func layoutSubviews() {
            super.layoutSubviews()
            playerLayer?.frame = bounds
        }
    }
}

private struct CaptionPicker: View {
    @Bindable var playerManager: VideoPlayerManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    playerManager.selectSubtitle(at: nil)
                    playerManager.selectExternalSubtitle(at: nil)
                    dismiss()
                } label: {
                    HStack {
                        Text("Off")
                        Spacer()
                        if playerManager.selectedSubtitleIndex == nil && playerManager.selectedExternalSubtitleIndex == nil {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                ForEach(Array(playerManager.subtitleOptions.enumerated()), id: \.offset) { index, option in
                    Button {
                        playerManager.selectSubtitle(at: index)
                        dismiss()
                    } label: {
                        HStack {
                            Text(option.displayName)
                            Spacer()
                            if playerManager.selectedSubtitleIndex == index {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
                ForEach(Array(playerManager.externalSubtitles.enumerated()), id: \.offset) { index, track in
                    Button {
                        playerManager.selectExternalSubtitle(at: index)
                        dismiss()
                    } label: {
                        HStack {
                            Text(track.label)
                            Spacer()
                            if playerManager.selectedExternalSubtitleIndex == index {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Captions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Renders the current side-loaded or generated caption in the device's
/// caption style (Settings › Accessibility › Subtitles & Captioning), falling
/// back to white-on-shadow.
struct CaptionOverlay: View {
    @Bindable var playerManager: VideoPlayerManager
    var bottomInset: CGFloat = 14
    /// Settings › Player › Caption Size.
    @AppStorage(CaptionSize.storageKey) private var captionScale = CaptionSize.medium.rawValue
    @Environment(\.scenePhase) private var scenePhase
    @State private var systemStyle = SystemCaptionStyle.current()

    var body: some View {
        VStack {
            Spacer()
            if playerManager.currentCaption == nil, let status = playerManager.generatedCaptionStatus {
                Text(status)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(.horizontal, 24)
                    .padding(.bottom, bottomInset)
            }
            if let caption = playerManager.currentCaption {
                Text(caption)
                    // The app's Caption Size multiplies the system's size.
                    .font(.system(size: CGFloat(16 * captionScale) * systemStyle.relativeSize, weight: .semibold))
                    .foregroundStyle(systemStyle.foreground)
                    .multilineTextAlignment(.center)
                    .modifier(CaptionEdgeModifier(edge: systemStyle.edge))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(systemStyle.background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.horizontal, 24)
                    .padding(.bottom, bottomInset)
                    .accessibilityLabel("Caption: \(caption)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        // The style is edited in Settings, so re-read it on every return.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { systemStyle = SystemCaptionStyle.current() }
        }
    }
}

/// The user's system caption appearance, read through MediaAccessibility.
/// Font family is left to the app; color, opacity, size and edge follow
/// the system.
struct SystemCaptionStyle: Equatable {
    enum EdgeStyle: Equatable { case none, shadow, raised, depressed, outline }

    var foreground: Color = .white
    var background: Color = .black.opacity(0.35)
    var relativeSize: CGFloat = 1
    var edge: EdgeStyle = .shadow

    static func current() -> SystemCaptionStyle {
        var style = SystemCaptionStyle()

        // "Copy" functions return +1 references.
        let foreground = MACaptionAppearanceCopyForegroundColor(.user, nil).takeRetainedValue()
        let foregroundOpacity = MACaptionAppearanceGetForegroundOpacity(.user, nil)
        // Fully transparent text would hide captions; treat it as unset.
        if foregroundOpacity > 0.05 {
            style.foreground = Color(uiColor: UIColor(cgColor: foreground)).opacity(Double(foregroundOpacity))
        }

        let background = MACaptionAppearanceCopyBackgroundColor(.user, nil).takeRetainedValue()
        let backgroundOpacity = MACaptionAppearanceGetBackgroundOpacity(.user, nil)
        if backgroundOpacity >= 0 && backgroundOpacity <= 1 {
            style.background = Color(uiColor: UIColor(cgColor: background)).opacity(Double(backgroundOpacity))
        }

        let size = MACaptionAppearanceGetRelativeCharacterSize(.user, nil)
        if size > 0 { style.relativeSize = min(max(size, 0.5), 2.5) }

        switch MACaptionAppearanceGetTextEdgeStyle(.user, nil) {
        case MACaptionAppearanceTextEdgeStyle.none: style.edge = .none
        case .raised: style.edge = .raised
        case .depressed: style.edge = .depressed
        case .uniform: style.edge = .outline
        default: style.edge = .shadow
        }
        return style
    }
}

private struct CaptionEdgeModifier: ViewModifier {
    let edge: SystemCaptionStyle.EdgeStyle

    @ViewBuilder
    func body(content: Content) -> some View {
        switch edge {
        case .none:
            content
        case .shadow:
            content
                .shadow(color: .black, radius: 2)
                .shadow(color: .black.opacity(0.8), radius: 4)
        case .raised:
            content.shadow(color: .black.opacity(0.9), radius: 0, x: 1, y: 1)
        case .depressed:
            content.shadow(color: .black.opacity(0.9), radius: 0, x: -1, y: -1)
        case .outline:
            content
                .shadow(color: .black, radius: 0.5)
                .shadow(color: .black, radius: 0.5)
                .shadow(color: .black, radius: 0.5)
        }
    }
}

/// Caption text scale; matches the desktop's caption size choices.
enum CaptionSize: Double, CaseIterable, Identifiable {
    case tiny = 0.5, extraSmall = 0.65, small = 0.8, medium = 1.0, large = 1.3, extraLarge = 1.6
    static let storageKey = "vixsrc_live_caption_scale"
    var id: Double { rawValue }
    var label: String {
        switch self {
        case .tiny: return "Tiny"
        case .extraSmall: return "Extra Small"
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        }
    }
}

/// Press feedback for every player control: a springy shrink and dim.
struct PlayerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(response: 0.12, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
