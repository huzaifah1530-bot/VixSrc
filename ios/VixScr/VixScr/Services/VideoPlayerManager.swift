import AVFoundation
import AVKit
import Observation

/// Manages native video playback with AVPlayer, tracking progress,
/// handling resume positions, and providing playback controls.
@MainActor
@Observable
final class VideoPlayerManager {
    private(set) var player: AVPlayer?
    private(set) var currentURL: URL?
    
    // Playback state
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isLoading = false
    private(set) var error: String?
    
    // Progress tracking
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var progressId: String?
    var onProgressUpdate: ((Double, Double) -> Void)? // (position, duration)
    
    init() {
        setupAudioSession()
    }
    
    deinit {
        cleanup()
    }
    
    // MARK: - Playback Control
    
    func load(url: URL, startPosition: Double = 0, progressId: String? = nil) {
        cleanup()
        
        self.currentURL = url
        self.progressId = progressId
        self.isLoading = true
        self.error = nil
        
        let player = AVPlayer(url: url)
        self.player = player
        
        // Observe player status
        statusObservation = player.observe(\.status, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                
                switch player.status {
                case .readyToPlay:
                    self.isLoading = false
                    if let item = player.currentItem {
                        self.duration = item.duration.seconds
                    }
                    // Seek to resume position if needed
                    if startPosition > 0 {
                        self.seek(to: startPosition)
                    }
                    self.setupPeriodicTimeObserver()
                    
                case .failed:
                    self.isLoading = false
                    self.error = player.error?.localizedDescription ?? "Failed to load video"
                    
                case .unknown:
                    break
                    
                @unknown default:
                    break
                }
            }
        }
    }
    
    func play() {
        player?.play()
        isPlaying = true
    }
    
    func pause() {
        player?.pause()
        isPlaying = false
        saveProgress()
    }
    
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    func seek(to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }
    
    func seekForward(_ seconds: Double = 10) {
        seek(to: min(currentTime + seconds, duration))
    }
    
    func seekBackward(_ seconds: Double = 10) {
        seek(to: max(currentTime - seconds, 0))
    }
    
    // MARK: - Progress Tracking
    
    private func setupPeriodicTimeObserver() {
        guard let player else { return }
        
        // Update every 0.5 seconds
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            
            self.currentTime = seconds
            
            // Notify progress update
            if self.duration > 0 {
                self.onProgressUpdate?(seconds, self.duration)
            }
            
            // Auto-save progress every 30 seconds
            if Int(seconds) % 30 == 0 {
                self.saveProgress()
            }
        }
        
        // Observe playback end
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            self?.handlePlaybackEnd()
        }
    }
    
    private func saveProgress() {
        guard currentTime > 0, duration > 0 else { return }
        onProgressUpdate?(currentTime, duration)
    }
    
    private func handlePlaybackEnd() {
        isPlaying = false
        // Mark as completed
        if duration > 0 {
            onProgressUpdate?(duration, duration)
        }
    }
    
    // MARK: - Audio Session
    
    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }
    
    // MARK: - Cleanup
    
    func cleanup() {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        
        statusObservation?.invalidate()
        statusObservation = nil
        
        player?.pause()
        player = nil
        
        isPlaying = false
        currentTime = 0
        duration = 0
        currentURL = nil
        progressId = nil
    }
}

// MARK: - Helpers

extension VideoPlayerManager {
    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }
    
    var formattedCurrentTime: String {
        formatTime(currentTime)
    }
    
    var formattedDuration: String {
        formatTime(duration)
    }
    
    var formattedTimeRemaining: String {
        formatTime(max(0, duration - currentTime))
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
