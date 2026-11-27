import AVFoundation
import AVKit
import MediaPlayer
import Observation
import UIKit
import Speech
import Translation

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
    /// The player sheet or mini player owns the video: the inline player
    /// going away (sheet dismissed into the mini player) must not pause it.
    @ObservationIgnored var keepsPlayingWhenHidden = false
    
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
    private(set) var generatedCaptionLocale: String?
    private(set) var translateGeneratedCaptions = false
    private(set) var generatedCaptionError: String?
    /// Live progress/diagnostic line for generated captions ("Audio received…",
    /// recognizer errors). Empty or nil once captions are flowing.
    private(set) var generatedCaptionStatus: String?
    private enum CaptionPreference: Codable, Equatable { case off, external(String), embedded(String), generated(String) }
    private static let captionPreferenceKey = "vela_caption_preference"
    @ObservationIgnored private var captionPreference: CaptionPreference?
    @ObservationIgnored private var externalCues: [SubtitleCue] = []
    @ObservationIgnored private var subtitleTask: Task<Void, Never>?
    @ObservationIgnored private var autoCaptionEngine: AnyObject?
    @ObservationIgnored private var restoreGeneratedOnForeground = false
    @ObservationIgnored private var generatedToRestore: (locale: String, translated: Bool)?
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []

    var canGenerateCaptions: Bool {
        if #available(iOS 27.0, *) { return true }
        return false
    }
    /// Shown in the captions menu when the OS cannot decode the player's
    /// audio for transcription, so the option is explained instead of missing.
    var generatedCaptionsUnavailableReason: String? {
        canGenerateCaptions ? nil
            : "Auto-generated captions need iOS 27 or later, because earlier versions don’t expose the player’s decoded audio."
    }
    /// The menu stays available whenever this device can play a native item:
    /// auto-generated captions are relevant even when the stream ships no
    /// subtitle tracks of its own.
    var hasAnySubtitles: Bool {
        player != nil || canGenerateCaptions || !subtitleOptions.isEmpty || !externalSubtitles.isEmpty
    }
    /// HLS audio tracks usually identify their spoken language. When a host
    /// omits it, the menu offers both languages instead of guessing.
    var spokenAudioLanguage: String? {
        guard let item = player?.currentItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible),
              let selected = item.currentMediaSelection.selectedMediaOption(in: group),
              let code = selected.locale?.language.languageCode?.identifier.lowercased() else { return nil }
        if code == "ja" { return "ja" }
        if code == "en" { return "en" }
        return nil
    }
    
    init() {
        if let saved = UserDefaults.standard.data(forKey: Self.captionPreferenceKey) {
            captionPreference = try? JSONDecoder().decode(CaptionPreference.self, from: saved)
        }
        setupAudioSession()
        observeAppLifecycle()
    }

    private func rememberCaption(_ choice: CaptionPreference) {
        captionPreference = choice
        if let data = try? JSONEncoder().encode(choice) {
            UserDefaults.standard.set(data, forKey: Self.captionPreferenceKey)
        }
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
        // Transcription cannot keep running for a paused item, and leaving it
        // attached holds the audio output. Restart from the saved choice when
        // the viewer comes back.
        if let locale = generatedCaptionLocale {
            restoreGeneratedOnForeground = true
            // What was actually running, which may be a title's default
            // rather than the remembered app-wide choice.
            generatedToRestore = (locale, translateGeneratedCaptions)
            stopGeneratedCaptions()
        }
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
        guard restoreGeneratedOnForeground else { return }
        restoreGeneratedOnForeground = false
        // Keep the viewer's chosen caption source across app switches.
        if let restore = generatedToRestore, let item = player?.currentItem {
            generatedToRestore = nil
            Task { [weak self] in
                guard let self, self.player?.currentItem === item else { return }
                await self.selectGeneratedCaptions(locale: restore.locale,
                                                   translated: restore.translated, remember: false)
            }
        }
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
        if case .external(let label) = captionPreference,
           let index = tracks.firstIndex(where: { $0.label == label }) {
            selectExternalSubtitle(at: index, remember: false)
        } else if captionPreference == nil, autoSelect, !tracks.isEmpty {
            let english = tracks.firstIndex { $0.label.lowercased().contains("english") } ?? 0
            selectExternalSubtitle(at: english, remember: false)
        }
    }

    func selectExternalSubtitle(at index: Int?, remember: Bool = true) {
        if index != nil { stopGeneratedCaptions() }
        subtitleTask?.cancel()
        externalCues = []
        currentCaption = nil
        guard let index, externalSubtitles.indices.contains(index) else {
            selectedExternalSubtitleIndex = nil
            if remember { rememberCaption(.off) }
            return
        }
        // Only one caption source at a time.
        if selectedSubtitleIndex != nil { selectSubtitle(at: nil, remember: false) }
        selectedExternalSubtitleIndex = index
        let track = externalSubtitles[index]
        if remember { rememberCaption(.external(track.label)) }
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

    // Stream (embedded) subtitles. AVPlayerLayer would draw them inside the
    // picture, so they'd scale and move with the zoom; Vela reads them and
    // draws them itself, pinned to the bottom of the screen.
    @ObservationIgnored private var legibleOutput: AVPlayerItemLegibleOutput?
    @ObservationIgnored private var legibleRelay: LegibleRelay?
    @ObservationIgnored private var embeddedCaption: String?

    /// Stream captions with the item time each belongs to, kept while a
    /// caption offset is set: AVFoundation pushes them at their own time,
    /// so showing them earlier or later means replaying this list.
    @ObservationIgnored private var embeddedEvents: [(time: Double, text: String?)] = []

    private func attachLegibleOutput(to item: AVPlayerItem) {
        let relay = LegibleRelay { [weak self] text, itemTime in
            guard let self else { return }
            self.embeddedCaption = text
            if self.captionOffset != 0, itemTime.isFinite { self.recordEmbeddedEvent(text, at: itemTime) }
            self.updateCaption(at: self.currentTime)
        }
        let output = AVPlayerItemLegibleOutput()
        output.suppressesPlayerRendering = true
        output.setDelegate(relay, queue: .main)
        item.add(output)
        legibleOutput = output
        legibleRelay = relay
        embeddedCaption = nil
        embeddedEvents = []
        applyLegibleAdvance()
    }

    private func detachLegibleOutput() {
        if let output = legibleOutput { player?.currentItem?.remove(output) }
        legibleOutput?.setDelegate(nil, queue: nil)
        legibleOutput = nil
        legibleRelay = nil
        embeddedCaption = nil
        embeddedEvents = []
    }

    private func recordEmbeddedEvent(_ text: String?, at time: Double) {
        // Usually in order; after a seek AVFoundation starts over elsewhere.
        var index = embeddedEvents.count
        while index > 0, embeddedEvents[index - 1].time > time { index -= 1 }
        if index > 0, abs(embeddedEvents[index - 1].time - time) < 0.01 {
            embeddedEvents[index - 1] = (time, text)
        } else {
            embeddedEvents.insert((time, text), at: index)
        }
        if embeddedEvents.count > 3_000 { embeddedEvents.removeFirst(embeddedEvents.count - 3_000) }
    }

    /// Earlier captions need AVFoundation to hand them over early.
    private func applyLegibleAdvance() {
        legibleOutput?.advanceIntervalForDelegateInvocation = captionOffset < 0 ? -captionOffset + 1 : 0
    }

    // MARK: - Caption timing

    /// Seconds captions are moved by for the current title; positive shows
    /// them later. Set from the title's settings.
    private(set) var captionOffset: Double = 0

    func setCaptionOffset(_ offset: Double) {
        let clamped = min(max(offset, CaptionTiming.range.lowerBound), CaptionTiming.range.upperBound)
        guard clamped != captionOffset else { return }
        captionOffset = clamped
        if clamped == 0 { embeddedEvents = [] }
        applyLegibleAdvance()
        updateCaption(at: currentTime)
    }

    private func updateCaption(at time: Double) {
        // Cues are looked up on the caption's own clock.
        let cueTime = time - captionOffset
        if generatedCaptionLocale == nil, selectedSubtitleIndex != nil {
            var text = embeddedCaption
            if captionOffset != 0 {
                // The last stream caption at or before the shifted time. One
                // older than 12 s is stale (a gap AVFoundation never filled).
                if let event = embeddedEvents.last(where: { $0.time <= cueTime }), cueTime - event.time < 12 {
                    text = event.text
                } else {
                    text = nil
                }
            }
            if text != currentCaption { currentCaption = text }
            return
        }
        let cues = generatedCaptionLocale == nil ? externalCues :
            (translateGeneratedCaptions ? translatedCues : generatedCues)
        guard !cues.isEmpty else {
            if currentCaption != nil { currentCaption = nil }
            return
        }
        // Binary search for the last cue starting at or before `cueTime`.
        var low = 0, high = cues.count - 1, found = -1
        while low <= high {
            let mid = (low + high) / 2
            if cues[mid].start <= cueTime { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        var lines: [String] = []
        if found >= 0 {
            var i = found
            // Overlapping cues (signs + dialogue) render together.
            while i >= 0, i >= found - 4 {
                let cue = cues[i]
                if cue.start <= cueTime, cue.end > cueTime { lines.insert(cue.text, at: 0) }
                i -= 1
            }
        }
        let text = lines.isEmpty ? nil : lines.joined(separator: "\n")
        if text != currentCaption { currentCaption = text }
    }
    
    // MARK: - Playback Control

    /// An asset that sends the headers and cookies a resolved stream needs.
    /// Shared with the segment recorder so it opens streams the same way.
    static func asset(url: URL, requestHeaders: [String: String], httpCookies: [HTTPCookie]) -> AVURLAsset {
        var options: [String: Any] = [
            AVURLAssetHTTPUserAgentKey: requestHeaders["User-Agent"] ?? StreamURLExtractor.userAgent
        ]
        if !httpCookies.isEmpty { options[AVURLAssetHTTPCookiesKey] = httpCookies }
        // Anime CDNs (MegaPlay, VidTube) refuse playlists and segments without
        // a matching Referer. AVFoundation has no public key for arbitrary
        // headers; this long-standing private key is what every iOS player uses.
        let extraHeaders = requestHeaders.filter { $0.key != "User-Agent" }
        if !extraHeaders.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = extraHeaders }
        return AVURLAsset(url: url, options: options)
    }
    
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
        
        let asset = Self.asset(url: url, requestHeaders: requestHeaders, httpCookies: httpCookies)
        let item = AVPlayerItem(asset: asset)
        attachLegibleOutput(to: item)
        let player = AVPlayer(playerItem: item)
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
                        self.updateAudioOptions(for: item)
                        if let audio = self.titleConfig?.audioDefault { self.applyTitleAudio(audio) }
                        // A title's default caption wins over the app-wide
                        // remembered one; if this episode has nothing that
                        // matches it, the app-wide choice stays.
                        let handled = self.titleConfig?.captionDefault.map { self.applyTitleCaption($0) } ?? false
                        if !handled, case .generated(let locale) = self.captionPreference {
                            let translated = locale == "ja-JP->en"
                            Task { await self.selectGeneratedCaptions(locale: translated ? "ja-JP" : locale,
                                                                      translated: translated, remember: false) }
                        }
                        self.publishNowPlayingInfo()
                        self.prepareRecordedSegments()
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
    // lookup (SkipDB then TheIntroDB / AniSkip) that starts once the duration is known,
    // so playback never waits for it. Validated against the real duration.

    /// Valid segments for the current item.
    private(set) var skipSegments: [SkipSegment] = []
    /// The intro the playhead is in; drives automatic intro skipping.
    var activeIntro: SkipSegment? { SkipSegments.activeIntro(skipSegments, at: currentTime) }
    var activeSkipSegment: SkipSegment? { SkipSegments.activeSegment(skipSegments, at: currentTime) }
    /// Read on every tick so turning the setting on/off applies immediately.
    @ObservationIgnored var autoSkipEnabled: () -> Bool = { false }
    @ObservationIgnored private var introKey = ""
    @ObservationIgnored private var introRaw: [SkipSegment]?
    @ObservationIgnored private var streamSkipSegments: [SkipSegment] = []
    @ObservationIgnored private var introFetch: (@Sendable (Double) async -> [SkipSegment])?
    @ObservationIgnored private var introFetchStarted = false
    @ObservationIgnored private var introLoadedAt = Date()
    @ObservationIgnored private var introTask: Task<Void, Never>?
    @ObservationIgnored private var autoSkipTracker = AutoSkipTracker()
    @ObservationIgnored private var autoSkipTrackerKey = ""

    // Custom per-show intro times (override found ones). Storage is the
    // app store's, reached through these hooks set by the view models.
    @ObservationIgnored var loadIntroOverride: (String) -> IntroOverride? = { _ in nil }
    /// `tv:<tmdbId>` / `tv:kai:<slug>`; nil for movies (no custom times).
    private(set) var introShowKey: String?
    @ObservationIgnored private var introShowTitle = ""
    private(set) var introOverride: IntroOverride?
    /// The found (not custom) intro for this episode, for the Intro menu.
    private(set) var foundIntro: SkipSegment?

    /// Call right after `load`. `episodeKey` is the progress id; `fetch` is
    /// given the duration (0 if unknown) and must return [] on failure.
    func configureIntroSkip(episodeKey: String, showKey: String? = nil, showTitle: String = "",
                            streamSegments: [SkipSegment],
                            fetch: (@Sendable (Double) async -> [SkipSegment])?) {
        introTask?.cancel()
        introKey = episodeKey
        introLoadedAt = Date()
        introFetchStarted = false
        introFetch = nil
        introRaw = nil
        streamSkipSegments = streamSegments
        skipSegments = []
        foundIntro = nil
        introShowKey = showKey
        introShowTitle = showTitle
        introOverride = showKey.flatMap { loadIntroOverride($0) }
        stopRecordedDetection()
        recordedFound = []
        foundSegmentStarts = [:]
        recordedPreparedFor = ""
        if autoSkipTrackerKey != episodeKey {
            autoSkipTracker = AutoSkipTracker()
            autoSkipTrackerKey = episodeKey
        } else {
            autoSkipTracker.restart()
        }
        introFetch = fetch
        recomputeSegments()
    }

    private func recomputeSegments() {
        let found = SkipSegments.merge(duration: duration, sources: [introRaw ?? [], streamSkipSegments])
        foundIntro = found.first { $0.kind == .intro }
        if titleConfig?.skipSource == .recorded {
            // The title uses the viewer's own segments instead of found ones.
            skipSegments = SkipSegments.valid(recordedFound, duration: duration)
        } else {
            skipSegments = SkipSegments.valid(SkipSegments.withOverride(found, introOverride), duration: duration)
        }
    }

    func skipIntro() {
        guard let segment = activeSkipSegment else { return }
        seek(to: SkipSegments.skipTarget(segment, in: skipSegments, at: currentTime))
    }

    private func applyIntro(_ raw: [SkipSegment]) {
        introRaw = raw
        recomputeSegments()
        autoSkipTracker.restart()
    }

    private func tickIntro(_ t: Double) {
        // A title using recorded segments never asks the online sources.
        if introRaw == nil, let fetch = introFetch, !introFetchStarted, titleConfig?.skipSource != .recorded,
           duration > 0 || Date().timeIntervalSince(introLoadedAt) > 6 {
            introFetchStarted = true
            let key = introKey
            let length = duration
            introTask = Task { @MainActor [weak self] in
                let list = await fetch(length)
                // A newer episode may have loaded meanwhile: drop stale answers.
                guard let self, !Task.isCancelled, self.introKey == key else { return }
                self.applyIntro(list)
            }
        }
        guard !skipSegments.isEmpty, !introKey.isEmpty else { return }
        // Intros follow the app-wide setting; recorded segments their own.
        let automatic = autoSkipEnabled()
        let eligible = skipSegments.filter { $0.autoSkip ?? ($0.kind == .intro && automatic) }
        guard !eligible.isEmpty else { return }
        // In a watch party only the host skips, through the room's seek.
        let party = PartySession.shared
        let allowed = !party.active || party.hostId == party.me
        if let target = autoSkipTracker.step(episodeKey: introKey, segments: eligible, time: t, allowed: allowed) {
            seek(to: target)
        }
    }

    // MARK: - Per-title settings
    //
    // The view models hand over the playing title's settings (Show / Movie /
    // Anime Settings) after `load`, and again whenever they change. Caption
    // and audio defaults apply once the stream is ready; skipping switches
    // between found timestamps and the viewer's recorded segments.

    @ObservationIgnored private(set) var titleConfig: TitlePlaybackConfig?
    /// Stream audio tracks (HLS alternate audio), for the title's default
    /// audio choice.
    private(set) var audioOptions: [AVMediaSelectionOption] = []
    private(set) var selectedAudioIndex: Int?
    /// Recorded segments found (or remembered) in this episode.
    @ObservationIgnored private var recordedFound: [SkipSegment] = []
    @ObservationIgnored private var segmentDetector: SegmentDetector?
    @ObservationIgnored private var recordedPreparedFor = ""
    /// Recorded segments being looked for right now, for the settings page.
    private(set) var searchingSegmentIDs: Set<UUID> = []
    /// Recorded segments found in this episode, with their start.
    private(set) var foundSegmentStarts: [UUID: Double] = [:]
    /// Called when a recorded segment is found: (segment, episode key,
    /// start, video length). The view model remembers it for next time.
    @ObservationIgnored var onRecordedSegmentFound: ((UUID, String, Double, Double) -> Void)?
    /// The episode key detection runs against (the progress id).
    var currentEpisodeKey: String { introKey }

    func applyTitleConfig(_ config: TitlePlaybackConfig?) {
        let previous = titleConfig
        titleConfig = config
        setCaptionOffset(config?.captionOffset ?? 0)
        let ready = player?.status == .readyToPlay
        if ready, config?.captionDefault != previous?.captionDefault {
            if let choice = config?.captionDefault { _ = applyTitleCaption(choice) }
        }
        if ready, config?.audioDefault != previous?.audioDefault, let audio = config?.audioDefault {
            applyTitleAudio(audio)
        }
        if config?.skipSignature != previous?.skipSignature {
            stopRecordedDetection()
            recordedFound = []
            foundSegmentStarts = [:]
            recordedPreparedFor = ""
            prepareRecordedSegments()
            recomputeSegments()
            autoSkipTracker.restart()
        }
    }

    /// Selects the title's default caption. False when nothing in this
    /// episode matches it.
    @discardableResult
    func applyTitleCaption(_ choice: CaptionChoice) -> Bool {
        switch choice {
        case .off:
            stopGeneratedCaptions()
            selectSubtitle(at: nil, remember: false)
            selectExternalSubtitle(at: nil, remember: false)
            return true
        case .generated(let locale):
            guard canGenerateCaptions, player?.currentItem != nil else { return false }
            let translated = locale == "ja-JP->en"
            if generatedCaptionLocale == (translated ? "ja-JP" : locale), translateGeneratedCaptions == translated { return true }
            Task { await selectGeneratedCaptions(locale: translated ? "ja-JP" : locale, translated: translated, remember: false) }
            return true
        case .language(let code, let label):
            // The exact track it was picked from, then any in its language.
            if let label {
                if let index = subtitleOptions.firstIndex(where: { $0.displayName == label }) {
                    if selectedSubtitleIndex != index { selectSubtitle(at: index, remember: false) }
                    return true
                }
                if let index = externalSubtitles.firstIndex(where: { $0.label == label }) {
                    if selectedExternalSubtitleIndex != index { selectExternalSubtitle(at: index, remember: false) }
                    return true
                }
            }
            if let index = subtitleOptions.firstIndex(where: { MediaLanguage.matches(option: $0, code: code) }) {
                if selectedSubtitleIndex != index { selectSubtitle(at: index, remember: false) }
                return true
            }
            if let index = externalSubtitles.firstIndex(where: { MediaLanguage.matches(label: $0.label, code: code) }) {
                if selectedExternalSubtitleIndex != index { selectExternalSubtitle(at: index, remember: false) }
                return true
            }
            return false
        }
    }

    /// Picks the title's default audio track. Sub / Dub is a choice of
    /// source, which the anime view model makes; only HLS tracks apply here.
    func applyTitleAudio(_ choice: AudioChoice) {
        guard case .language(let code, let label) = choice else { return }
        let index = label.flatMap { label in audioOptions.firstIndex { $0.displayName == label } }
            ?? audioOptions.firstIndex { MediaLanguage.matches(option: $0, code: code) }
        if let index, index != selectedAudioIndex { selectAudio(at: index) }
    }

    private func updateAudioOptions(for item: AVPlayerItem) {
        guard let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) else {
            audioOptions = []
            selectedAudioIndex = nil
            return
        }
        audioOptions = group.options
        if let selected = item.currentMediaSelection.selectedMediaOption(in: group) {
            selectedAudioIndex = audioOptions.firstIndex { $0 === selected }
        } else {
            selectedAudioIndex = nil
        }
    }

    func selectAudio(at index: Int) {
        guard let item = player?.currentItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible),
              audioOptions.indices.contains(index) else { return }
        item.select(audioOptions[index], in: group)
        selectedAudioIndex = index
    }

    /// Recorded segments for this episode: remembered positions apply at
    /// once; the rest are looked for as the episode plays.
    private func prepareRecordedSegments() {
        guard let config = titleConfig, config.skipSource == .recorded, !config.recordedSegments.isEmpty,
              !introKey.isEmpty, duration > 0, let item = player?.currentItem else { return }
        let marker = "\(introKey)|\(config.skipSignature.joined(separator: ","))"
        guard recordedPreparedFor != marker else { return }
        recordedPreparedFor = marker
        stopRecordedDetection()

        var known: [SkipSegment] = []
        var targets: [SegmentDetector.Target] = []
        var starts: [UUID: Double] = [:]
        for segment in config.recordedSegments {
            if let match = segment.match(for: introKey, videoDuration: duration) {
                known.append(recordedSkip(segment, start: match.start))
                starts[segment.id] = match.start
            } else if let print = SegmentLibrary.load(segment.id) {
                targets.append(SegmentDetector.Target(segment: segment, print: print))
            }
        }
        recordedFound = known
        foundSegmentStarts = starts
        if !targets.isEmpty {
            segmentDetector = SegmentDetector(item: item, targets: targets,
                                              playbackTime: { [weak self] in self?.livePosition ?? 0 }) { [weak self] id, start in
                self?.recordedSegmentFound(id, start: start)
            }
            searchingSegmentIDs = segmentDetector?.searching ?? []
        }
        recomputeSegments()
    }

    private func recordedSkip(_ segment: RecordedSegment, start: Double) -> SkipSegment {
        let begin = max(0, start)
        return SkipSegment(kind: .custom, start: begin, end: start + segment.duration, source: .recorded,
                           label: segment.buttonTitle, autoSkip: segment.autoSkip)
    }

    private func recordedSegmentFound(_ id: UUID, start: Double) {
        searchingSegmentIDs.remove(id)
        guard let segment = titleConfig?.recordedSegments.first(where: { $0.id == id }) else { return }
        // Must fit this video; a "match" past the end is noise.
        guard start > -segment.duration, duration <= 0 || start < duration - SkipSegments.minSegmentSeconds else { return }
        recordedFound.removeAll { $0.label == segment.buttonTitle && abs($0.start - max(0, start)) < 1 }
        recordedFound.append(recordedSkip(segment, start: start))
        foundSegmentStarts[id] = start
        recomputeSegments()
        // Found partway in: let the tracker treat it as just reached, so an
        // automatic skip still happens.
        autoSkipTracker.restart()
        onRecordedSegmentFound?(id, introKey, start, duration)
    }

    private func stopRecordedDetection() {
        segmentDetector?.stop()
        segmentDetector = nil
        searchingSegmentIDs = []
    }

    func rawPlay() { player?.play(); isPlaying = true }
    func rawPause() { player?.pause(); isPlaying = false }
    func rawSeek(to seconds: Double) {
        let clamped = max(0, duration > 0 ? min(seconds, duration - 0.5) : seconds)
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
        pendingResumePosition = 0
        segmentDetector?.noteSeek()
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
        noteCaptionSeek(clamped)
        segmentDetector?.noteSeek()
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
        if introRaw != nil || !streamSkipSegments.isEmpty || introOverride != nil || !recordedFound.isEmpty { recomputeSegments() }
        prepareRecordedSegments()
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
        if case .embedded(let name) = captionPreference,
           let index = subtitleOptions.firstIndex(where: { $0.displayName == name }) {
            item.select(subtitleOptions[index], in: group)
            selectedSubtitleIndex = index
            return
        }
        if captionPreference != nil {
            item.select(nil, in: group)
            selectedSubtitleIndex = nil
            return
        }
        if let selected = item.currentMediaSelection.selectedMediaOption(in: group) {
            selectedSubtitleIndex = subtitleOptions.firstIndex { $0 === selected }
        } else {
            selectedSubtitleIndex = nil
        }
    }

    func selectSubtitle(at index: Int?, remember: Bool = true) {
        if index != nil { stopGeneratedCaptions() }
        if index == nil, remember {
            stopGeneratedCaptions()
            rememberCaption(.off)
        }
        guard let item = player?.currentItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else { return }
        if let index, subtitleOptions.indices.contains(index) {
            if selectedExternalSubtitleIndex != nil { selectExternalSubtitle(at: nil, remember: false) }
            item.select(subtitleOptions[index], in: group)
            selectedSubtitleIndex = index
            embeddedCaption = nil
            updateCaption(at: currentTime)
            if remember { rememberCaption(.embedded(subtitleOptions[index].displayName)) }
        } else {
            item.select(nil, in: group)
            selectedSubtitleIndex = nil
            embeddedCaption = nil
            updateCaption(at: currentTime)
        }
    }

    @ObservationIgnored private var generatedCues: [SubtitleCue] = []
    @ObservationIgnored private var translatedCues: [SubtitleCue] = []

    /// A seek moves the playhead away from the audio the recognizer is
    /// decoding; restart it there so new cues stay in sync.
    private func noteCaptionSeek(_ time: Double) {
        if #available(iOS 27.0, *), let engine = autoCaptionEngine as? AutoCaptionEngine {
            engine.noteSeek(to: time)
        }
    }

    func selectGeneratedCaptions(locale: String, translated: Bool = false, remember: Bool = true) async {
        generatedCaptionError = nil
        guard #available(iOS 27.0, *) else {
            generatedCaptionError = generatedCaptionsUnavailableReason
            return
        }
        guard let item = player?.currentItem else { return }
        guard await AutoCaptionEngine.authorize() else {
            generatedCaptionError = AutoCaptionEngine.Failure.permission.localizedDescription
            return
        }
        guard player?.currentItem === item else { return }
        stopGeneratedCaptions()
        let engine = AutoCaptionEngine()
        do {
            try engine.start(item: item, locale: Locale(identifier: locale),
                             playbackTime: { [weak self] in self?.currentTime ?? 0 },
                             onStatus: { [weak self] status in
                self?.generatedCaptionStatus = status.isEmpty ? nil : status
            },
                             onCues: { [weak self] cues in
                guard let self else { return }
                self.generatedCues = cues
                self.updateCaption(at: self.currentTime)
            })
            autoCaptionEngine = engine
            generatedCaptionLocale = locale
            translateGeneratedCaptions = translated
            // Only hide the other tracks once transcription actually started,
            // so a failure leaves the viewer with their previous captions.
            selectSubtitle(at: nil, remember: false)
            selectExternalSubtitle(at: nil, remember: false)
            if remember { rememberCaption(.generated(translated ? "ja-JP->en" : locale)) }
        } catch {
            generatedCaptionError = error.localizedDescription
            engine.stop()
        }
    }

    private func stopGeneratedCaptions() {
        if #available(iOS 27.0, *) {
            (autoCaptionEngine as? AutoCaptionEngine)?.stop()
        }
        autoCaptionEngine = nil
        generatedCaptionLocale = nil
        generatedCaptionStatus = nil
        translateGeneratedCaptions = false
        generatedCues = []
        translatedCues = []
        translatedSource = [:]
        currentCaption = nil
    }

    @ObservationIgnored private var translatedSource: [Double: String] = [:]

    func nextCaptionToTranslate() -> SubtitleCue? {
        guard translateGeneratedCaptions, generatedCaptionLocale == "ja-JP" else { return nil }
        return generatedCues.first { cue in
            cue.start >= currentTime - 20 && cue.start <= currentTime + 8 &&
            translatedSource[cue.start] != cue.text
        }
    }

    func acceptTranslatedCaption(_ cue: SubtitleCue, text: String) {
        guard translateGeneratedCaptions else { return }
        translatedCues.removeAll { abs($0.start - cue.start) < 0.01 }
        translatedCues.append(SubtitleCue(start: cue.start, end: cue.end, text: text))
        translatedCues.sort { $0.start < $1.start }
        translatedSource[cue.start] = cue.text
        updateCaption(at: currentTime)
    }

    func setCaptionTranslationError(_ error: Error) {
        generatedCaptionError = "Japanese translation is unavailable: \(error.localizedDescription)"
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
        stopGeneratedCaptions()
        detachLegibleOutput()
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
        streamSkipSegments = []
        introFetch = nil
        introFetchStarted = false
        skipSegments = []
        foundIntro = nil
        introOverride = nil
        introShowKey = nil
        // Title settings are handed over again after the next load.
        stopRecordedDetection()
        recordedFound = []
        foundSegmentStarts = [:]
        recordedPreparedFor = ""
        titleConfig = nil
        captionOffset = 0
        audioOptions = []
        selectedAudioIndex = nil
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

/// Receives stream subtitle text from AVFoundation on the main queue and
/// hands it to the player manager.
private final class LegibleRelay: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    /// (text, item time it belongs to).
    private let deliver: @MainActor (String?, Double) -> Void

    init(deliver: @escaping @MainActor (String?, Double) -> Void) {
        self.deliver = deliver
    }

    nonisolated func legibleOutput(_ output: AVPlayerItemLegibleOutput,
                                   didOutputAttributedStrings strings: [NSAttributedString],
                                   nativeSampleBuffers nativeSamples: [Any],
                                   forItemTime itemTime: CMTime) {
        let lines = strings
            .map { line in line.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in !line.isEmpty }
        let text = lines.isEmpty ? nil : lines.joined(separator: "\n")
        let seconds = itemTime.seconds
        // The delegate queue is .main.
        MainActor.assumeIsolated { deliver(text, seconds) }
    }
}
