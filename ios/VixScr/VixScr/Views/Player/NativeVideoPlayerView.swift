import SwiftUI
import AVKit
import UIKit

/// Native video player view wrapping AVPlayer with custom controls.
/// Replaces the WebView-based player with a proper AVPlayerLayer.
struct NativeVideoPlayerView: View {
    @Bindable var playerManager: VideoPlayerManager
    var onPlaybackFailure: (() -> Void)? = nil
    @State private var showControls = true
    @State private var controlsTimer: Timer?
    @State private var isFullscreen = false
    private let controlsAnimation = Animation.spring(response: 0.38, dampingFraction: 0.88)
    
    var body: some View {
        ZStack {
            // Video layer
            VideoPlayerLayer(player: playerManager.player, isFullscreen: isFullscreen)
                .background(Color.black)
                .onTapGesture {
                    toggleControls()
                }

            // Side-loaded captions sit above the controls' timeline when visible.
            CaptionOverlay(playerManager: playerManager, bottomInset: showControls ? 120 : 14)
                .animation(controlsAnimation, value: showControls)
            
            // Loading indicator
            if playerManager.isLoading {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.5)
            }
            
            // Error message
            if let error = playerManager.error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
            }
            
            // Custom controls overlay
            if !playerManager.isLoading && playerManager.error == nil {
                PlayerControlsOverlay(
                    playerManager: playerManager,
                    onHideControls: { hideControls() },
                    onToggleFullscreen: { isFullscreen = true }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .opacity(showControls ? 1 : 0)
                .offset(y: showControls ? 0 : 24)
                .scaleEffect(showControls ? 1 : 0.985, anchor: .bottom)
                .allowsHitTesting(showControls)
                .accessibilityHidden(!showControls)
                .animation(controlsAnimation, value: showControls)
            }
        }
        .onAppear {
            // Start playing automatically when view appears
            if playerManager.player != nil && !playerManager.isPlaying {
                playerManager.play()
                scheduleControlsHide()
            }
        }
        .onDisappear {
            if !isFullscreen {
                playerManager.pause()
            }
            controlsTimer?.invalidate()
        }
        .onChange(of: playerManager.error) { _, error in
            if error != nil { onPlaybackFailure?() }
        }
        .fullScreenCover(isPresented: $isFullscreen) {
            SystemVideoPlayerView(playerManager: playerManager)
                .ignoresSafeArea()
                .preferredColorScheme(.dark)
        }
    }
    
    private func toggleControls() {
        showControls.toggle()
        if showControls {
            scheduleControlsHide()
        } else {
            controlsTimer?.invalidate()
        }
    }
    
    private func scheduleControlsHide() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak playerManager] _ in
            Task { @MainActor [weak playerManager] in
                guard playerManager?.isPlaying == true else { return }
                showControls = false
            }
        }
    }
    
    private func hideControls() {
        showControls = false
        controlsTimer?.invalidate()
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

/// Custom controls overlay with play/pause, seek bar, and time labels
struct PlayerControlsOverlay: View {
    @Bindable var playerManager: VideoPlayerManager
    let onHideControls: () -> Void
    let onToggleFullscreen: () -> Void
    
    @State private var isSeeking = false
    @State private var seekPosition: Double = 0
    @State private var showCaptions = false
    
    var body: some View {
        VStack {
            Spacer()
            
            // Keep one timeline. Secondary actions sit above the centered
            // playback controls to avoid crowding them on narrow screens.
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Spacer()
                    Button { showCaptions = true } label: {
                        Image(systemName: "captions.bubble")
                    }
                    .buttonStyle(PlayerButtonStyle())
                    .disabled(!playerManager.hasAnySubtitles)
                    .opacity(playerManager.hasAnySubtitles ? 1 : 0.45)
                    .accessibilityLabel("Captions")
                    Button(action: onToggleFullscreen) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(PlayerButtonStyle())
                    .accessibilityLabel("Full screen")
                }
                .padding(.horizontal, 12)

                HStack(spacing: 24) {
                    Button {
                        playerManager.seekBackward(10)
                    } label: {
                        Image(systemName: "gobackward.10")
                            .font(.title2)
                    }
                    .buttonStyle(PlayerButtonStyle())

                    Button {
                        playerManager.togglePlayPause()
                        if playerManager.isPlaying { onHideControls() }
                    } label: {
                        Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title)
                    }
                    .buttonStyle(PlayerButtonStyle())

                    Button {
                        playerManager.seekForward(10)
                    } label: {
                        Image(systemName: "goforward.10")
                            .font(.title2)
                    }
                    .buttonStyle(PlayerButtonStyle())
                }
                .frame(maxWidth: .infinity)

                // The timeline spans the player width and sits directly above
                // the bottom edge of the video.
                scrubber
            }
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .background {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.8)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
        }
        .sheet(isPresented: $showCaptions) {
            CaptionPicker(playerManager: playerManager)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var scrubber: some View {
        GeometryReader { geometry in
            let availableWidth = max(1, geometry.size.width)
            let duration = playerManager.duration
            let currentFraction = duration > 0
                ? (isSeeking ? seekPosition / duration : playerManager.progress)
                : 0
            let clampedFraction = min(1, max(0, currentFraction))

            ZStack(alignment: .topLeading) {
                VStack(spacing: 2) {
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.28))
                            .frame(height: 5)
                        Capsule()
                            .fill(.white)
                            .frame(width: availableWidth * clampedFraction, height: 5)
                        Circle()
                            .fill(.white)
                            .frame(width: 12, height: 12)
                            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                            .offset(x: min(max(0, availableWidth - 12), availableWidth * clampedFraction - 6))
                    }
                    .frame(width: availableWidth, height: 30)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard duration > 0 else { return }
                                isSeeking = true
                                let fraction = min(1, max(0, value.location.x / availableWidth))
                                seekPosition = fraction * duration
                            }
                            .onEnded { value in
                                guard duration > 0 else { return }
                                let fraction = min(1, max(0, value.location.x / availableWidth))
                                playerManager.seek(to: fraction * duration)
                                isSeeking = false
                            }
                    )
                    HStack {
                        Text(formatTime(isSeeking ? seekPosition : playerManager.currentTime))
                        Spacer(minLength: 12)
                        Text("-" + formatTime(isSeeking ? max(0, duration - seekPosition) : playerManager.duration - playerManager.currentTime))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.86))
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 48, alignment: .top)
        }
        .frame(height: 48)
        .padding(.horizontal, 20)
    }
    
    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
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

private struct SystemVideoPlayerView: UIViewControllerRepresentable {
    let playerManager: VideoPlayerManager
    private var player: AVPlayer? { playerManager.player }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.delegate = context.coordinator
        controller.player = player
        if let overlay = controller.contentOverlayView {
            let host = UIHostingController(rootView: CaptionOverlay(playerManager: playerManager, bottomInset: 40))
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = false
            host.view.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: overlay.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
            ])
            context.coordinator.captionHost = host
        }
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.exitsFullScreenWhenPlaybackEnds = false
        // Metadata and poster art are published centrally by VideoPlayerManager.
        controller.updatesNowPlayingInfoCenter = false
        return controller
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var captionHost: UIViewController?

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
        ) {
            completionHandler(true)
        }
    }
}

/// Button style for player controls
struct PlayerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1.0)
    }
}
