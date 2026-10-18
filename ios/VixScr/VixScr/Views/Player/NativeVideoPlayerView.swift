import SwiftUI
import AVKit
import UIKit

/// Native video player: AVPlayerLayer plus Vela's own controls, used both
/// inline and in fullscreen (no system AVPlayerViewController).
///
/// Gestures:
///   - tap: show / hide controls
///   - double-tap left / right third: skip back / forward (Settings → Player)
///   - hold left / right third: 2× speed while held
struct NativeVideoPlayerView: View {
    @Bindable var playerManager: VideoPlayerManager
    var onPlaybackFailure: (() -> Void)? = nil
    @State private var isFullscreen = false

    var body: some View {
        PlayerSurface(playerManager: playerManager, isFullscreen: false) {
            setFullscreen(true)
        }
        .onAppear {
            if playerManager.player != nil && !playerManager.isPlaying { playerManager.play() }
        }
        .onDisappear {
            if !isFullscreen { playerManager.pause() }
        }
        .onChange(of: playerManager.error) { _, error in
            if error != nil { onPlaybackFailure?() }
        }
        .fullScreenCover(isPresented: $isFullscreen, onDismiss: { rotate(to: .portrait) }) {
            PlayerSurface(playerManager: playerManager, isFullscreen: true) {
                setFullscreen(false)
            }
            .background(Color.black.ignoresSafeArea())
            .ignoresSafeArea()
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
            .preferredColorScheme(.dark)
        }
    }

    private func setFullscreen(_ on: Bool) {
        isFullscreen = on
        rotate(to: on ? .landscapeRight : .portrait)
    }

    private func rotate(to mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}

// MARK: - Player surface

/// Video, captions, gesture zones and controls. Shared by the inline and
/// fullscreen presentations so both behave identically.
private struct PlayerSurface: View {
    @Bindable var playerManager: VideoPlayerManager
    let isFullscreen: Bool
    let onToggleFullscreen: () -> Void

    @Environment(AppStore.self) private var store
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var showCaptions = false
    @State private var seekFeedback: SeekFeedback?
    @State private var feedbackTask: Task<Void, Never>?
    @GestureState private var holdingSide: Side?
    @State private var boostSide: Side?
    @State private var lastHoldEnded = Date.distantPast

    enum Side { case left, right }

    struct SeekFeedback: Equatable {
        var side: Side
        var seconds: Int
        var pulse: Int
    }

    private let spring = Animation.spring(response: 0.38, dampingFraction: 0.82)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                VideoPlayerLayer(player: playerManager.player, isFullscreen: isFullscreen)
                    .background(Color.black)
                    .allowsHitTesting(false)

                CaptionOverlay(playerManager: playerManager, bottomInset: showControls ? (isFullscreen ? 110 : 76) : 16)
                    .animation(spring, value: showControls)

                gestureZones(width: geo.size.width)

                seekFeedbackView(size: geo.size)

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
                        .scaleEffect(showControls ? 1 : 0.97)
                        .allowsHitTesting(showControls)
                        .accessibilityHidden(!showControls)
                }

                speedBadge
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .animation(spring, value: showControls)
        .animation(spring, value: playerManager.isLoading)
        .onAppear { scheduleHide() }
        .onChange(of: playerManager.isPlaying) { _, playing in
            if playing { scheduleHide() } else { reveal(autoHide: false) }
        }
        .onChange(of: holdingSide) { _, side in
            if let side {
                boostSide = side
                playerManager.beginSpeedBoost()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            } else if boostSide != nil {
                boostSide = nil
                lastHoldEnded = Date()
                playerManager.endSpeedBoost()
            }
        }
        .sheet(isPresented: $showCaptions) {
            CaptionPicker(playerManager: playerManager)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: Gesture zones

    private func gestureZones(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            zone(.left).frame(width: width * 0.35)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }
            zone(.right).frame(width: width * 0.35)
        }
    }

    private func zone(_ side: Side) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                TapGesture(count: 2).onEnded { doubleTap(side) }
                    .exclusively(before: TapGesture().onEnded { singleTap() })
            )
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.35)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .updating($holdingSide) { value, state, _ in
                        if case .second(true, _) = value { state = side }
                    }
            )
    }

    private func singleTap() {
        // A finished hold also ends as a tap; ignore it.
        guard Date().timeIntervalSince(lastHoldEnded) > 0.3 else { return }
        if seekFeedback != nil { return }
        toggleControls()
    }

    private func doubleTap(_ side: Side) {
        let step = store.seekInterval
        if side == .left { playerManager.seekBackward(Double(step)) } else { playerManager.seekForward(Double(step)) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        // Consecutive double-taps on the same side add up, YouTube-style.
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            if var current = seekFeedback, current.side == side {
                current.seconds += step
                current.pulse += 1
                seekFeedback = current
            } else {
                seekFeedback = SeekFeedback(side: side, seconds: step, pulse: 0)
            }
        }
        feedbackTask?.cancel()
        feedbackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { seekFeedback = nil }
        }
    }

    // MARK: Feedback views

    @ViewBuilder
    private func seekFeedbackView(size: CGSize) -> some View {
        if let feedback = seekFeedback {
            let isLeft = feedback.side == .left
            ZStack {
                // Curved highlight hugging the tapped edge.
                Ellipse()
                    .fill(.white.opacity(0.14))
                    .frame(width: size.width * 0.75, height: size.height * 1.6)
                    .offset(x: isLeft ? -size.width * 0.5 : size.width * 0.5)

                VStack(spacing: 6) {
                    Image(systemName: isLeft ? "backward.fill" : "forward.fill")
                        .font(.system(size: isFullscreen ? 30 : 22, weight: .semibold))
                        .symbolEffect(.bounce, value: feedback.pulse)
                    Text("\(feedback.seconds) seconds")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .contentTransition(.numericText())
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 6)
                .offset(x: isLeft ? -size.width * 0.32 : size.width * 0.32)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
        }
    }

    @ViewBuilder
    private var speedBadge: some View {
        VStack {
            if playerManager.isSpeedBoosted {
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
                .padding(.top, isFullscreen ? 24 : 12)
                .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.8)))
            }
            Spacer()
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: playerManager.isSpeedBoosted)
        .allowsHitTesting(false)
    }

    // MARK: Controls

    private var controls: some View {
        ZStack {
            // Scrims only; they never take touches.
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: isFullscreen ? 120 : 70)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                    .frame(height: isFullscreen ? 150 : 90)
            }
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                transport
                Spacer(minLength: 0)
                PlayerScrubber(playerManager: playerManager, isFullscreen: isFullscreen) {
                    reveal(autoHide: false)
                } onEnd: {
                    scheduleHide()
                }
            }
            .padding(.horizontal, isFullscreen ? 44 : 14)
            .padding(.top, isFullscreen ? 20 : 10)
            .padding(.bottom, isFullscreen ? 20 : 8)
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            if isFullscreen {
                Text(playerManager.nowPlayingDisplayTitle)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.4), radius: 4)
            }
            Spacer()
            GlassIconButton(systemImage: playerManager.selectedSubtitleIndex != nil || playerManager.selectedExternalSubtitleIndex != nil
                            ? "captions.bubble.fill" : "captions.bubble",
                            size: isFullscreen ? 44 : 36,
                            label: "Captions") {
                showCaptions = true
                reveal(autoHide: true)
            }
            .disabled(!playerManager.hasAnySubtitles)
            .opacity(playerManager.hasAnySubtitles ? 1 : 0.4)

            GlassIconButton(systemImage: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                            size: isFullscreen ? 44 : 36,
                            label: isFullscreen ? "Exit full screen" : "Full screen") {
                onToggleFullscreen()
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
                .contentTransition(.symbolEffect(.replace.downUp))
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
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Image(systemName: forward ? "goforward.\(seconds)" : "gobackward.\(seconds)")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white)
                .symbolEffect(.bounce, value: taps)
                .rotationEffect(.degrees(Double(taps % 2 == 0 ? 0 : (forward ? 20 : -20))))
                .animation(.spring(response: 0.3, dampingFraction: 0.5), value: taps)
                .frame(width: size * 1.9, height: size * 1.9)
                .contentShape(Circle())
        }
        .buttonStyle(PlayerButtonStyle())
        .accessibilityLabel(forward ? "Skip forward \(seconds) seconds" : "Skip back \(seconds) seconds")
    }
}

/// Small round glass button used in the top bar.
private struct GlassIconButton: View {
    let systemImage: String
    let size: CGFloat
    let label: String
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
                .vixGlass(.regular, cornerRadius: 999)
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
                .animation(.spring(response: 0.28, dampingFraction: 0.75), value: isSeeking)
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

/// UIViewRepresentable wrapper for AVPlayerLayer
struct VideoPlayerLayer: UIViewRepresentable {
    let player: AVPlayer?
    let isFullscreen: Bool
    
    func makeUIView(context: Context) -> PlayerUIView {
        PlayerUIView(player: player, isFullscreen: isFullscreen)
    }
    
    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.isFullscreen = isFullscreen
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
        
        var player: AVPlayer? {
            didSet {
                if player !== oldValue {
                    setupPlayerLayer()
                }
            }
        }
        
        init(player: AVPlayer?, isFullscreen: Bool) {
            self.player = player
            self.isFullscreen = isFullscreen
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
            layer.videoGravity = .resizeAspect
            layer.frame = bounds
            self.layer.addSublayer(layer)
            self.playerLayer = layer
            // No automatic Picture in Picture: leaving the app should close
            // playback, not shrink it into the Dynamic Island. PiP is still
            // available manually from the fullscreen player's controls.
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

/// Renders the current side-loaded caption (anime soft subs) in the
/// standard white-on-shadow subtitle style.
struct CaptionOverlay: View {
    @Bindable var playerManager: VideoPlayerManager
    var bottomInset: CGFloat = 14

    var body: some View {
        VStack {
            Spacer()
            if let caption = playerManager.currentCaption {
                Text(caption)
                    .font(.system(.callout, design: .default).weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .shadow(color: .black, radius: 2)
                    .shadow(color: .black.opacity(0.8), radius: 4)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.horizontal, 24)
                    .padding(.bottom, bottomInset)
                    .accessibilityLabel("Caption: \(caption)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
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
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}