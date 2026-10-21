import AVFoundation
import AVKit
import MediaPlayer
import Observation
import UIKit

/// Manages native video playback with AVPlayer, tracking progress,
/// handling resume positions, and providing playback controls.
@MainActor
@Observable
final class VideoPlayerManager {
    private(set) var player: AVPlayer?
    private(set) var currentURL: URL?
    /// Fullscreen player is up. Kept here (not in the view) so it survives
    /// switching episodes; cleared when the player sheet closes.
    var wantsFullscreen = false
    
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
    private var rateObservation: NSKeyValueObservation?
    private var progressId: String?
    private var pendingResumePosition: Double = 0
    private var lastSavedSecond = -1
    private var lastNowPlayingSecond = -1
    private var nowPlayingTitle = "Vela"
    private var nowPlayingSubtitle: String?
    private var nowPlayingArtwork: UIImage?
    private var nowPlayingArtworkURL: URL?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    var onProgressUpdate: (@MainActor (Double, Double) -> Void)? // (position, duration)

    private(set) var subtitleOptions: [AVMediaSelectionOption] = []
    private(set) var selectedSubtitleIndex: Int?

    // Side-loaded WebVTT tracks (anime soft subs). Rendered by
    // `CaptionOverlay` because AVPlayer can't attach them to an HLS item.
    private(set) var externalSubtitles: [ExternalSubtitle] = []
    private(set) var selectedExternalSubtitleIndex: Int?
    private(set) var currentCaption: String?
    @ObservationIgnored private var externalCues: [SubtitleCue] = []
    @ObservationIgnored private var subtitleTask: Task<Void, Never>?
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []

    var hasAnySubtitles: Bool { !subtitleOptions.isEmpty || !externalSubtitles.isEmpty }
    
    init() {
        setupAudioSession()
        observeAppLifecycle()
    }

    /// Leaving the app stops playback outright. Keeping the audio session and
    /// Now Playing info alive made iOS shrink the app into the Dynamic Island
    /// (and Lock Screen player) instead of simply closing it.
    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleEnterBackground() }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleEnterForeground() }
        })
    }

    private func handleEnterBackground() {
        // Picture in Picture the user started keeps playing; anything else stops.
        if pipController?.isPictureInPictureActive == true { return }
        // Pause only this device; in a watch party, leaving the app must not
        // pause everyone (we re-sync on return).
        rawPause()
        saveProgress()
        if !RemoteNowPlaying.shared.isActive { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
        removeRemoteCommands()
        // Remote playback may keep the session alive for lock screen controls.
        if !RemoteNowPlaying.shared.isActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func handleEnterForeground() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    // MARK: - Picture in Picture

    private weak var pipController: AVPictureInPictureController?

    func attach(pictureInPicture controller: AVPictureInPictureController) {
        pipController = controller
    }

    func startPictureInPicture() {
        guard let pipController else { return }
        setupAudioSession()
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else if pipController.isPictureInPicturePossible {
            pipController.startPictureInPicture()
        } else {
            // Not ready yet (layer still attaching); try once more shortly.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                self?.pipController?.startPictureInPicture()
            }
        }
    }

    // MARK: - External subtitles

    func setExternalSubtitles(_ tracks: [ExternalSubtitle], autoSelect: Bool) {
        externalSubtitles = tracks
        selectedExternalSubtitleIndex = nil
        externalCues = []
        currentCaption = nil
        subtitleTask?.cancel()
        if autoSelect, !tracks.isEmpty {
            let english = tracks.firstIndex { $0.label.lowercased().contains("english") } ?? 0
            selectExternalSubtitle(at: english)
        }
    }

    func selectExternalSubtitle(at index: Int?) {
        subtitleTask?.cancel()
        externalCues = []
        currentCaption = nil
        guard let index, externalSubtitles.indices.contains(index) else {
            selectedExternalSubtitleIndex = nil
            return
        }
        // Only one caption source at a time.
        if selectedSubtitleIndex != nil { selectSubtitle(at: nil) }
        selectedExternalSubtitleIndex = index
        let track = externalSubtitles[index]
        subtitleTask = Task { [weak self] in
            var request = URLRequest(url: track.url)
            request.setValue(StreamURLExtractor.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(track.referer, forHTTPHeaderField: "Referer")
            guard let (data, _) = try? await URLSession.shared.data(for: request), !Task.isCancelled else { return }
            let cues = WebVTT.parse(String(decoding: data, as: UTF8.self))
            guard let self, self.selectedExternalSubtitleIndex == index else { return }
            self.externalCues = cues
            self.updateCaption(at: self.currentTime)
        }
    }

    private func updateCaption(at time: Double) {
        guard !externalCues.isEmpty else {
            if currentCaption != nil { currentCaption = nil }
            return
        }
        // Binary search for the last cue starting at or before `time`.
        var low = 0, high = externalCues.count - 1, found = -1
        while low <= high {
            let mid = (low + high) / 2
            if externalCues[mid].start <= time { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        var lines: [String] = []
        if found >= 0 {
            var i = found
            // Overlapping cues (signs + dialogue) render together.
            while i >= 0, i >= found - 4 {
                let cue = externalCues[i]
                if cue.start <= time, cue.end > time { lines.insert(cue.text, at: 0) }
                i -= 1
            }
        }
        let text = lines.isEmpty ? nil : lines.joined(separator: "\n")
        if text != currentCaption { currentCaption = text }
    }
    
    // MARK: - Playback Control
    
    func load(url: URL, requestHeaders: [String: String] = [:], httpCookies: [HTTPCookie] = [], startPosition: Double = 0, progressId: String? = nil, mediaTitle: String? = nil, subtitle: String? = nil, artworkURL: URL? = nil) {
        cleanup()
        
        self.currentURL = url
        self.progressId = progressId
        self.pendingResumePosition = max(0, startPosition)
        self.lastSavedSecond = -1
        self.lastNowPlayingSecond = -1
        setNowPlayingMetadata(title: mediaTitle, subtitle: subtitle, artworkURL: artworkURL)
        self.isLoading = true
        self.error = nil
        
        var options: [String: Any] = [
            AVURLAssetHTTPUserAgentKey: requestHeaders["User-Agent"] ?? StreamURLExtractor.userAgent
        ]
        if !httpCookies.isEmpty { options[AVURLAssetHTTPCookiesKey] = httpCookies }
        // Anime CDNs (MegaPlay, VidTube) refuse playlists and segments without
        // a matching Referer. AVFoundation has no public key for arbitrary
        // headers; this long-standing private key is what every iOS player uses.
        let extraHeaders = requestHeaders.filter { $0.key != "User-Agent" }
        if !extraHeaders.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = extraHeaders }
        let asset = AVURLAsset(url: url, options: options)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        self.player = player
        installRemoteCommands()
        publishNowPlayingInfo()

        rateObservation = player.observe(\.rate, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player === player else { return }
                self.isPlaying = player.rate > 0
                self.publishNowPlayingInfo()
            }
        }
        
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
                        self.publishNowPlayingInfo()
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
    
    // MARK: - Watch Together hooks
    //
    // While in a party, the user's play / pause / seek go to the room first
    // (it may refuse, e.g. host-only control); the sync loop then drives the
    // player through the raw* methods below, which bypass the party.

    /// Returns false to block a user action. Set by `PartySession`.
    var partyGate: ((PartyAction) -> Bool)?
    enum PartyAction { case play, pause, seek(Double) }
    /// Called when the current item plays to the end.
    var onEnded: (() -> Void)?

    var isWaiting: Bool { player?.timeControlStatus == .waitingToPlayAtSpecifiedRate || isLoading }

    // MARK: - Intro skipping
    //
    // Timestamps come from the stream itself (anime hosts) or a background
    // lookup (TheIntroDB / AniSkip) that starts once the duration is known,
    // so playback never waits for it. Validated against the real duration.

    /// Valid segments for the current item.
    private(set) var skipSegments: [SkipSegment] = []
    /// The intro the playhead is in; drives the Skip Intro button.
    var activeIntro: SkipSegment? { SkipSegments.activeIntro(skipSegments, at: currentTime) }
    /// Read on every tick so turning the setting on/off applies immediately.
    @ObservationIgnored var autoSkipEnabled: () -> Bool = { false }
    @ObservationIgnored private var introKey = ""
    @ObservationIgnored private var introRaw: [SkipSegment]?
    @ObservationIgnored private var introFetch: (@Sendable (Double) async -> [SkipSegment])?
    @ObservationIgnored private var introFetchStarted = false
    @ObservationIgnored private var introLoadedAt = Date()
    @ObservationIgnored private var introTask: Task<Void, Never>?
    /// Successful lookups this session, by episode key (survive source switches).
    @ObservationIgnored private var fetchedIntros: [String: [SkipSegment]] = [:]
    @ObservationIgnored private var autoSkipTracker = AutoSkipTracker()
    @ObservationIgnored private var autoSkipTrackerKey = ""

    /// Call right after `load`. `episodeKey` is the progress id; `fetch` is
    /// given the duration (0 if unknown) and must return [] on failure.
    func configureIntroSkip(episodeKey: String, streamSegments: [SkipSegment],
                            fetch: (@Sendable (Double) async -> [SkipSegment])?) {
        introTask?.cancel()
        introKey = episodeKey
        introLoadedAt = Date()
        introFetchStarted = false
        introFetch = nil
        introRaw = nil
        skipSegments = []
        if autoSkipTrackerKey != episodeKey {
            autoSkipTracker = AutoSkipTracker()
            autoSkipTrackerKey = episodeKey
        } else {
            autoSkipTracker.restart()
        }
        if streamSegments.contains(where: { $0.kind == .intro }) {
            applyIntro(streamSegments)
        } else if let cached = fetchedIntros[episodeKey] {
            applyIntro(cached)
        } else {
            introFetch = fetch
        }
    }

    func skipIntro() {
        guard let intro = activeIntro else { return }
        seek(to: intro.end)
    }

    private func applyIntro(_ raw: [SkipSegment]) {
        introRaw = raw
        skipSegments = SkipSegments.valid(raw, duration: duration)
        autoSkipTracker.restart()
    }

    private func tickIntro(_ t: Double) {
        if introRaw == nil, let fetch = introFetch, !introFetchStarted,
           duration > 0 || Date().timeIntervalSince(introLoadedAt) > 6 {
            introFetchStarted = true
            let key = introKey
            let length = duration
            introTask = Task { @MainActor [weak self] in
                let list = await fetch(length)
                // A newer episode may have loaded meanwhile: drop stale answers.
                guard let self, !Task.isCancelled, self.introKey == key else { return }
                self.fetchedIntros[key] = list
                self.applyIntro(list)
            }
        }
        guard !skipSegments.isEmpty, !introKey.isEmpty else { return }
        // In a watch party only the host skips, through the room's seek.
        let party = PartySession.shared
        let allowed = autoSkipEnabled() && (!party.active || party.hostId == party.me)
        if let target = autoSkipTracker.step(episodeKey: introKey, segments: skipSegments, time: t, allowed: allowed) {
            seek(to: target)
        }
    }

    func rawPlay() { player?.play(); isPlaying = true }
    func rawPause() { player?.pause(); isPlaying = false }
    func rawSeek(to seconds: Double) {
        let clamped = max(0, duration > 0 ? min(seconds, duration - 0.5) : seconds)
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
        pendingResumePosition = 0
        updateCaption(at: clamped)
    }
    /// The player's real position right now. `currentTime` only updates on
    /// the periodic observer, so it lags by up to its interval; syncing
    /// against it made the party "correct" drift that wasn't there.
    var livePosition: Double {
        guard let player else { return currentTime }
        let t = player.currentTime().seconds
        return t.isFinite ? t : currentTime
    }

    func setRate(_ rate: Float) {
        guard let player, player.timeControlStatus != .paused, !isSpeedBoosted, player.rate != rate else { return }
        player.rate = rate
    }

    func play() {
        if let gate = partyGate, !gate(.play) { return }
        if let player {
            player.play()
        } else {
            postWebRemoteCommand("play")
        }
        isPlaying = true
        publishNowPlayingInfo()
    }
    
    func pause() {
        if let gate = partyGate, !gate(.pause) { return }
        if let player {
            player.pause()
        } else {
            postWebRemoteCommand("pause")
        }
        isPlaying = false
        saveProgress()
        publishNowPlayingInfo()
    }
    
    /// Title (and episode, when known) shown in the fullscreen top bar.
    var nowPlayingDisplayTitle: String {
        guard let nowPlayingSubtitle, !nowPlayingSubtitle.isEmpty else { return nowPlayingTitle }
        return "\(nowPlayingTitle) · \(nowPlayingSubtitle)"
    }

    /// True while the viewer holds the edge of the player for 2× speed.
    private(set) var isSpeedBoosted = false

    func beginSpeedBoost() {
        // 2× would pull this viewer off a watch party's timeline.
        guard let player, !isSpeedBoosted, partyGate == nil else { return }
        isSpeedBoosted = true
        player.rate = 2
    }

    func endSpeedBoost() {
        guard isSpeedBoosted else { return }
        isSpeedBoosted = false
        player?.rate = 1
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
        if let gate = partyGate, !gate(.seek(clamped)) { return }
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        if let player {
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            postWebRemoteCommand("seek", position: clamped)
        }
        currentTime = clamped
        updateCaption(at: clamped)
        pendingResumePosition = 0
        publishNowPlayingInfo()
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
        
        // Update every 0.25 seconds — fine enough for side-loaded captions.
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }

                let seconds = time.seconds
                guard seconds.isFinite else { return }

                self.currentTime = seconds
                self.updateCaption(at: seconds)
                self.tickIntro(seconds)

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
                if Int(seconds) % 15 == 0 && Int(seconds) != self.lastNowPlayingSecond {
                    self.lastNowPlayingSecond = Int(seconds)
                    self.publishNowPlayingInfo()
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
        onEnded?()
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
        if let introRaw { skipSegments = SkipSegments.valid(introRaw, duration: seconds) }
        publishNowPlayingInfo()
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
            if selectedExternalSubtitleIndex != nil { selectExternalSubtitle(at: nil) }
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

    // MARK: - Now Playing / remote controls

    private func loadNowPlayingArtwork(from url: URL?) {
        artworkTask?.cancel()
        nowPlayingArtwork = nil
        guard let url else { return }
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  !Task.isCancelled,
                  let artwork = UIImage(data: data) else { return }
            self?.nowPlayingArtwork = artwork
            self?.publishNowPlayingInfo()
        }
    }

    func setNowPlayingMetadata(title: String?, subtitle: String?, artworkURL: URL?) {
        nowPlayingTitle = title ?? "Vela"
        nowPlayingSubtitle = subtitle
        lastNowPlayingSecond = -1
        if nowPlayingArtworkURL != artworkURL {
            nowPlayingArtworkURL = artworkURL
            nowPlayingArtwork = nil
            loadNowPlayingArtwork(from: artworkURL)
        }
        if player == nil { installRemoteCommands() }
        publishNowPlayingInfo()
    }

    private func postWebRemoteCommand(_ action: String, position: Double? = nil) {
        var userInfo: [String: Any] = ["action": action]
        if let position { userInfo["position"] = position }
        NotificationCenter.default.post(name: .velaWebRemoteCommand, object: nil, userInfo: userInfo)
    }

    func updateWebPlaybackPosition(_ position: Double, duration: Double, isPlaying playing: Bool = true) {
        guard player == nil, position.isFinite, duration.isFinite, duration > 0 else { return }
        currentTime = max(0, position)
        self.duration = duration
        let playbackStateChanged = isPlaying != playing
        isPlaying = playing
        let second = Int(position)
        guard playbackStateChanged || (second % 15 == 0 && second != lastNowPlayingSecond) else { return }
        lastNowPlayingSecond = second
        publishNowPlayingInfo()
    }

    /// Local playback never publishes Now Playing info or lock screen
    /// controls, so iOS has nothing to show in the Dynamic Island.
    private static let localNowPlayingEnabled = false

    private func publishNowPlayingInfo() {
        guard Self.localNowPlayingEnabled else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlayingTitle,
            MPMediaItemPropertyArtist: "Vela",
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if let nowPlayingSubtitle, !nowPlayingSubtitle.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = nowPlayingSubtitle
        }
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let image = nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = Self.makeNowPlayingArtwork(image)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// MediaPlayer may request artwork from one of its own background queues.
    /// Keep its synchronous provider outside the manager's MainActor isolation;
    /// otherwise Swift's executor check traps when the system calls it off-main.
    private nonisolated static func makeNowPlayingArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        let boundsSize = image.size
        return MPMediaItemArtwork(boundsSize: boundsSize) { _ in image }
    }

    private func installRemoteCommands() {
        guard Self.localNowPlayingEnabled else { return }
        removeRemoteCommands()
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true

        let play = center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.play() }
            return .success
        }
        remoteCommandTargets.append((center.playCommand, play))

        let pause = center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.pause() }
            return .success
        }
        remoteCommandTargets.append((center.pauseCommand, pause))

        let position = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            Task { @MainActor [weak self] in self?.seek(to: seconds) }
            return .success
        }
        remoteCommandTargets.append((center.changePlaybackPositionCommand, position))

        center.skipForwardCommand.preferredIntervals = [10]
        let forward = center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.seekForward(10) }
            return .success
        }
        remoteCommandTargets.append((center.skipForwardCommand, forward))

        center.skipBackwardCommand.preferredIntervals = [10]
        let backward = center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.seekBackward(10) }
            return .success
        }
        remoteCommandTargets.append((center.skipBackwardCommand, backward))
    }

    private func removeRemoteCommands() {
        for (command, target) in remoteCommandTargets {
            command.removeTarget(target)
        }
        remoteCommandTargets.removeAll()
        // The remote (computer) controls own the command center while active.
        guard Self.localNowPlayingEnabled, !RemoteNowPlaying.shared.isActive else { return }
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = false
        center.pauseCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
    }
    
    // MARK: - Cleanup
    
    func cleanup() {
        saveProgress()
        artworkTask?.cancel()
        artworkTask = nil
        rateObservation?.invalidate()
        rateObservation = nil
        removeRemoteCommands()
        if !RemoteNowPlaying.shared.isActive { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }

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
        isSpeedBoosted = false
        
        isPlaying = false
        currentTime = 0
        duration = 0
        currentURL = nil
        progressId = nil
        pendingResumePosition = 0
        subtitleOptions = []
        selectedSubtitleIndex = nil
        subtitleTask?.cancel()
        externalSubtitles = []
        selectedExternalSubtitleIndex = nil
        externalCues = []
        currentCaption = nil
        nowPlayingArtwork = nil
        nowPlayingArtworkURL = nil
        nowPlayingSubtitle = nil
        // Lookups in flight are dropped; per-episode caches and the
        // "already skipped" state survive for the next load.
        introTask?.cancel()
        introTask = nil
        introKey = ""
        introRaw = nil
        introFetch = nil
        introFetchStarted = false
        skipSegments = []
    }
}

extension Notification.Name {
    static let velaWebRemoteCommand = Notification.Name("VelaWebRemoteCommand")
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
