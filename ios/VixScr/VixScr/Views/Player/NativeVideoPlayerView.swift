import SwiftUI
import AVKit
import UIKit

/// Native video player view wrapping AVPlayer with custom controls.
/// Replaces the WebView-based player with a proper AVPlayerLayer.
struct NativeVideoPlayerView: View {
    @Bindable var playerManager: VideoPlayerManager
    var posterURL: URL? = nil
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
                    posterURL: posterURL,
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
            SystemVideoPlayerView(player: playerManager.player)
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
            if AVPictureInPictureController.isPictureInPictureSupported(),
               let controller = AVPictureInPictureController(playerLayer: layer) {
                controller.canStartPictureInPictureAutomaticallyFromInline = true
                pictureInPictureController = controller
                // The native AVPlayerViewController used for fullscreen lives
                // inside a SwiftUI fullScreenCover, so it isn't an inline
                // presentation and automatic-from-inline PiP doesn't apply.
                // Start PiP explicitly as the app enters the background.
                backgroundObserver = NotificationCenter.default.addObserver(
                    forName: UIApplication.didEnterBackgroundNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    guard let self,
                          self.isFullscreen,
                          self.player?.timeControlStatus == .playing,
                          let pipController = self.pictureInPictureController,
                          pipController.isPictureInPicturePossible else { return }
                    pipController.startPictureInPicture()
                }
            }
        }

        deinit {
            if let backgroundObserver {
                NotificationCenter.default.removeObserver(backgroundObserver)
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
    var posterURL: URL? = nil
    let onHideControls: () -> Void
    let onToggleFullscreen: () -> Void
    
    @State private var isSeeking = false
    @State private var seekPosition: Double = 0
    @State private var showCaptions = false
    @State private var scrubPreviewImage: UIImage?
    
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
                    .disabled(playerManager.subtitleOptions.isEmpty)
                    .opacity(playerManager.subtitleOptions.isEmpty ? 0.45 : 1)
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
                    if isSeeking {
                        Color.clear.frame(height: 84)
                    }

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

                if isSeeking {
                    scrubPreview
                        .offset(x: min(max(0, availableWidth - 116), max(0, availableWidth * clampedFraction - 58)))
                        .task(id: Int(seekPosition.rounded(.down))) {
                            scrubPreviewImage = nil
                            guard let asset = playerManager.player?.currentItem?.asset else { return }
                            let generator = AVAssetImageGenerator(asset: asset)
                            generator.appliesPreferredTrackTransform = true
                            generator.maximumSize = CGSize(width: 320, height: 180)
                            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
                            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
                            do {
                                try await Task.sleep(nanoseconds: 100_000_000)
                                let time = CMTime(seconds: seekPosition.rounded(.down), preferredTimescale: 600)
                                let result = try await generator.image(at: time)
                                guard !Task.isCancelled else { return }
                                scrubPreviewImage = UIImage(cgImage: result.image)
                            } catch {
                                // Some streams don't expose frame thumbnails; keep the time preview usable.
                            }
                        }
                }
            }
            .frame(height: isSeeking ? 132 : 48, alignment: .top)
        }
        .frame(height: isSeeking ? 132 : 48)
        .padding(.horizontal, 20)
    }

    private var scrubPreview: some View {
        VStack(spacing: 4) {
            Group {
                if let scrubPreviewImage {
                    Image(uiImage: scrubPreviewImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    AsyncImage(url: posterURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Rectangle()
                                .fill(.ultraThinMaterial)
                                .overlay {
                                    Image(systemName: "film")
                                        .font(.title3.weight(.medium))
                                        .foregroundStyle(.white.opacity(0.65))
                                }
                        }
                    }
                }
            }
            .frame(width: 116, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.white.opacity(0.22), lineWidth: 1)
            }
            Text(formatTime(seekPosition))
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 3)
        }
        .frame(width: 116)
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
                    dismiss()
                } label: {
                    HStack {
                        Text("Off")
                        Spacer()
                        if playerManager.selectedSubtitleIndex == nil {
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

private struct SystemVideoPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer?

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.delegate = context.coordinator
        controller.player = player
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
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
