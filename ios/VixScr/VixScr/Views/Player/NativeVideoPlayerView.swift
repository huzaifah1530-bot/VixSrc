import SwiftUI
import AVKit

/// Native video player view wrapping AVPlayer with custom controls.
/// Replaces the WebView-based player with a proper AVPlayerLayer.
struct NativeVideoPlayerView: View {
    @Bindable var playerManager: VideoPlayerManager
    @State private var showControls = true
    @State private var controlsTimer: Timer?
    
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
                    onHideControls: { hideControls() }
                )
                .transition(.opacity)
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
            playerManager.pause()
            controlsTimer?.invalidate()
        }
    }
    
    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.3)) {
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
        withAnimation(.easeInOut(duration: 0.3)) {
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
    
    @State private var isSeeking = false
    @State private var seekPosition: Double = 0
    
    var body: some View {
        VStack {
            Spacer()
            
            // Bottom controls
            VStack(spacing: 16) {
                // Progress bar
                progressBar
                
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
    }
    
    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background track
                Rectangle()
                    .fill(.white.opacity(0.3))
                    .frame(height: 4)
                
                // Progress
                Rectangle()
                    .fill(.white)
                    .frame(width: geometry.size.width * (isSeeking ? (seekPosition / playerManager.duration) : playerManager.progress), height: 4)
            }
            .clipShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isSeeking = true
                        let progress = max(0, min(1, value.location.x / geometry.size.width))
                        seekPosition = progress * playerManager.duration
                    }
                    .onEnded { value in
                        let progress = max(0, min(1, value.location.x / geometry.size.width))
                        let newPosition = progress * playerManager.duration
                        playerManager.seek(to: newPosition)
                        isSeeking = false
                    }
            )
        }
        .frame(height: 44)
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

/// Button style for player controls
struct PlayerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.6 : 1.0)
    }
}
