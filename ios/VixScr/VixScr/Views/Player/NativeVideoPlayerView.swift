import SwiftUI
import AVKit

/// Native video player view wrapping AVPlayer with custom controls.
/// Replaces the WebView-based player with a proper AVPlayerLayer.
struct NativeVideoPlayerView: View {
    @Bindable var playerManager: VideoPlayerManager
    @State private var showControls = true
    @State private var controlsTimer: Timer?
    @State private var isFullscreen = false
    
    var body: some View {
        ZStack {
            // Video layer
            VideoPlayerLayer(player: playerManager.player)
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
            if showControls && !playerManager.isLoading && playerManager.error == nil {
                PlayerControlsOverlay(
                    playerManager: playerManager,
                    onHideControls: { hideControls() },
                    onToggleFullscreen: { isFullscreen = true }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.98, anchor: .bottom)))
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
        .fullScreenCover(isPresented: $isFullscreen) {
            SystemVideoPlayerView(player: playerManager.player)
                .ignoresSafeArea()
                .preferredColorScheme(.dark)
        }
    }
    
    private func toggleControls() {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
            showControls.toggle()
        }
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
                withAnimation(.easeInOut(duration: 0.3)) {
                    showControls = false
                }
            }
        }
    }
    
    private func hideControls() {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
            showControls = false
        }
        controlsTimer?.invalidate()
    }
}

/// UIViewRepresentable wrapper for AVPlayerLayer
struct VideoPlayerLayer: UIViewRepresentable {
    let player: AVPlayer?
    
    func makeUIView(context: Context) -> PlayerUIView {
        PlayerUIView(player: player)
    }
    
    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.player = player
    }
    
    final class PlayerUIView: UIView {
        private var playerLayer: AVPlayerLayer?
        
        var player: AVPlayer? {
            didSet {
                if player !== oldValue {
                    setupPlayerLayer()
                }
            }
        }
        
        init(player: AVPlayer?) {
            self.player = player
            super.init(frame: .zero)
            setupPlayerLayer()
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        private func setupPlayerLayer() {
            playerLayer?.removeFromSuperlayer()
            
            guard let player else { return }
            
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspect
            layer.frame = bounds
            self.layer.addSublayer(layer)
            self.playerLayer = layer
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
            
            // Bottom controls
            VStack(spacing: 16) {
                // Progress bar
                scrubber
                
                // Control buttons and time
                HStack(spacing: 20) {
                    // Time elapsed
                    Text(isSeeking ? formatTime(seekPosition) : playerManager.formattedCurrentTime)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(minWidth: 50, alignment: .leading)
                    
                    // Skip back
                    Button {
                        playerManager.seekBackward(10)
                    } label: {
                        Image(systemName: "gobackward.10")
                            .font(.title2)
                    }
                    .buttonStyle(PlayerButtonStyle())
                    
                    // Play/Pause
                    Button {
                        playerManager.togglePlayPause()
                        if playerManager.isPlaying {
                            onHideControls()
                        }
                    } label: {
                        Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title)
                    }
                    .buttonStyle(PlayerButtonStyle())
                    
                    // Skip forward
                    Button {
                        playerManager.seekForward(10)
                    } label: {
                        Image(systemName: "goforward.10")
                            .font(.title2)
                    }
                    .buttonStyle(PlayerButtonStyle())
                    
                    // Time remaining
                    Text(isSeeking ? "-\(formatTime(playerManager.duration - seekPosition))" : "-\(playerManager.formattedTimeRemaining)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(minWidth: 50, alignment: .trailing)
                }
                .padding(.horizontal, 20)

                HStack {
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
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 20)
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
            let availableWidth = max(1, geometry.size.width - 40)
            let duration = playerManager.duration
            let currentFraction = duration > 0
                ? (isSeeking ? seekPosition / duration : playerManager.progress)
                : 0
            let clampedFraction = min(1, max(0, currentFraction))

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
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .offset(x: availableWidth * clampedFraction - 8)
                }
                .frame(width: availableWidth, height: 30)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }
                            isSeeking = true
                            let fraction = min(1, max(0, (value.location.x - 20) / availableWidth))
                            seekPosition = fraction * duration
                        }
                        .onEnded { value in
                            guard duration > 0 else { return }
                            let fraction = min(1, max(0, (value.location.x - 20) / availableWidth))
                            playerManager.seek(to: fraction * duration)
                            isSeeking = false
                        }
                )
                HStack {
                    Text(formatTime(isSeeking ? seekPosition : playerManager.currentTime))
                    Spacer()
                    Text("-" + formatTime(isSeeking ? max(0, duration - seekPosition) : playerManager.duration - playerManager.currentTime))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.86))
                .frame(width: availableWidth)
            }
        }
        .frame(height: 52)
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
        controller.player = player
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.exitsFullScreenWhenPlaybackEnds = false
        controller.updatesNowPlayingInfoCenter = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
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
