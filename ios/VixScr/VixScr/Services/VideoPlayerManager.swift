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
    private var durationObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var progressId: String?
    private var pendingResumePosition: Double = 0
    private var lastSavedSecond = -1
    var onProgressUpdate: (@MainActor (Double, Double) -> Void)? // (position, duration)

    private(set) var subtitleOptions: [AVMediaSelectionOption] = []
    private(set) var selectedSubtitleIndex: Int?
    
    init() {
        setupAudioSession()
    }
    
    // MARK: - Playback Control
    
    func load(url: URL, startPosition: Double = 0, progressId: String? = nil) {
        cleanup()
        
        self.currentURL = url
        self.progressId = progressId
        self.pendingResumePosition = max(0, startPosition)
        self.lastSavedSecond = -1
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
                        self.updateDuration(from: item)
                        self.observeDuration(for: item)
                        self.updateSubtitleOptions(for: item)
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
        let clamped = max(0, duration > 0 ? min(seconds, duration) : seconds)
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
        pendingResumePosition = 0
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
            Task { @MainActor [weak self] in
                guard let self else { return }

                let seconds = time.seconds
                guard seconds.isFinite else { return }

                self.currentTime = seconds

                // Notify progress update
                if self.duration > 0 {
                    self.onProgressUpdate?(seconds, self.duration)
                }

                // Persist often enough to resume accurately without writing to
                // UserDefaults on every half-second UI tick.
                if Int(seconds) % 5 == 0 && Int(seconds) != self.lastSavedSecond {
                    self.lastSavedSecond = Int(seconds)
                    self.saveProgress()
                }
            }
        }
        
        // Observe playback end
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePlaybackEnd()
            }
        }
    }
    
    private func saveProgress() {
        let playerDuration = player?.currentItem?.duration.seconds ?? 0
        if duration <= 0, playerDuration.isFinite, playerDuration > 0 {
            duration = playerDuration
        }
        let actualTime = player?.currentTime().seconds ?? currentTime
        if actualTime.isFinite { currentTime = max(0, actualTime) }
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

    private func observeDuration(for item: AVPlayerItem) {
        durationObservation?.invalidate()
        durationObservation = item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateDuration(from: item)
            }
        }
    }

    private func updateDuration(from item: AVPlayerItem) {
        let seconds = item.duration.seconds
        guard seconds.isFinite, seconds > 0 else { return }
        duration = seconds
        if pendingResumePosition > 0 {
            let resume = min(pendingResumePosition, seconds)
            pendingResumePosition = 0
            player?.seek(to: CMTime(seconds: resume, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = resume
        }
    }

    private func updateSubtitleOptions(for item: AVPlayerItem) {
        guard let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else {
            subtitleOptions = []
            selectedSubtitleIndex = nil
            return
        }
        subtitleOptions = group.options
        if let selected = item.currentMediaSelection.selectedMediaOption(in: group) {
            selectedSubtitleIndex = subtitleOptions.firstIndex { $0 === selected }
        } else {
            selectedSubtitleIndex = nil
        }
    }

    func selectSubtitle(at index: Int?) {
        guard let item = player?.currentItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else { return }
        if let index, subtitleOptions.indices.contains(index) {
            item.select(subtitleOptions[index], in: group)
            selectedSubtitleIndex = index
        } else {
            item.select(nil, in: group)
            selectedSubtitleIndex = nil
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
        saveProgress()

        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        
        statusObservation?.invalidate()
        statusObservation = nil
        durationObservation?.invalidate()
        durationObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        
        player?.pause()
        player = nil
        
        isPlaying = false
        currentTime = 0
        duration = 0
        currentURL = nil
        progressId = nil
        pendingResumePosition = 0
        subtitleOptions = []
        selectedSubtitleIndex = nil
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
