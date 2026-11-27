import AVFoundation
import Foundation
import Observation

/// Plays one episode for the segment recorder and fingerprints everything
/// it shows and plays, so the part the viewer marks can be saved. Separate
/// from the title's own player: recording never touches watch progress,
/// the mini player or a watch party.
@MainActor
@Observable
final class SegmentRecorderModel {
    enum Stage: Equatable {
        case choosing
        case loading(String)
        case marking
        case failed(String)
    }

    var stage: Stage = .choosing
    private(set) var episode: EpisodeRef?
    private(set) var player: AVPlayer?
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    var start: Double?
    var end: Double?
    /// 0...1 while the marked part is being played to record it.
    private(set) var recordingProgress: Double?
    /// Bumped as fingerprints arrive, so capture status redraws.
    private(set) var captureRevision = 0

    static let minimumLength = SkipSegments.minSegmentSeconds
    static let maximumLength = SkipSegments.maxIntroSeconds

    @ObservationIgnored private var timeline = FeatureTimeline()
    @ObservationIgnored private var tap: PlaybackFeatureTap?
    /// Reads the marked part straight from the stream's files.
    @ObservationIgnored private var reader: HLSStreamReader?
    /// Why reading the stream directly failed, for the fallback message.
    private(set) var directFailure: String?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var previewEnd: Double?
    @ObservationIgnored private var recordingCancelled = false
    @ObservationIgnored private var initialPosition: Double = 0
    @ObservationIgnored private var lastRevisionSecond = -1

    /// Sound comes from reading the stream directly; if that failed for
    /// this stream, only the picture can be recorded.
    var audioPossible: Bool { directFailure == nil }
    var isRecording: Bool { recordingProgress != nil }

    // MARK: Loading

    func open(_ episode: EpisodeRef, context: TitleContext, startingAt position: Double = 0) {
        teardown()
        self.episode = episode
        start = nil
        end = nil
        timeline = FeatureTimeline()
        initialPosition = max(0, position)
        stage = .loading("Opening \(episode.label)…")
        loadTask = Task { @MainActor [weak self] in
            let stream = await context.resolveStream(episode)
            guard let self, !Task.isCancelled, self.episode == episode else { return }
            guard let stream else {
                self.stage = .failed("Couldn't open \(episode.label). Try another episode, or switch server in the player.")
                return
            }
            self.attach(stream)
        }
    }

    private func attach(_ stream: StreamURLExtractor.ResolvedStream) {
        let asset = VideoPlayerManager.asset(url: stream.url, requestHeaders: stream.requestHeaders, httpCookies: stream.httpCookies)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        self.player = player

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.statusChanged() }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in self?.tick(time.seconds) }
        }

        // Pictures of whatever plays here are kept too, as a fallback for
        // streams Vela can't read directly.
        let tap = PlaybackFeatureTap(item: item, visual: true, audioFeed: nil)
        tap.onVisual = { [weak self] sample in self?.timeline.add(sample) }
        tap.start()
        self.tap = tap
        reader = HLSStreamReader(url: stream.url, requestHeaders: stream.requestHeaders, cookies: stream.httpCookies,
                                 audioLanguage: audioLanguage)
        directFailure = nil
    }

    /// The audio language the title plays in (its default audio setting).
    var audioLanguage: String?

    private func statusChanged() {
        guard let item = player?.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            guard stage != .marking else { return }
            let seconds = item.duration.seconds
            duration = seconds.isFinite && seconds > 0 ? seconds : 0
            stage = .marking
            if initialPosition > 0 { seek(to: initialPosition) }
            player?.play()
        case .failed:
            stage = .failed(item.error?.localizedDescription ?? "This stream wouldn't play. Try another episode.")
        default:
            break
        }
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite, let player else { return }
        currentTime = seconds
        isPlaying = player.rate > 0
        if duration <= 0, let length = player.currentItem?.duration.seconds, length.isFinite, length > 0 {
            duration = length
        }
        if let previewEnd, seconds >= previewEnd {
            self.previewEnd = nil
            player.pause()
        }
        let second = Int(seconds)
        if second != lastRevisionSecond {
            lastRevisionSecond = second
            captureRevision += 1
        }
    }

    func teardown() {
        loadTask?.cancel()
        loadTask = nil
        recordingCancelled = true
        tap?.stop()
        tap = nil
        reader = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        recordingProgress = nil
    }

    // MARK: Playback

    func togglePlay() {
        guard let player else { return }
        previewEnd = nil
        if player.rate > 0 { player.pause() } else { player.play() }
        isPlaying = player.rate > 0
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        let target = max(0, duration > 0 ? min(seconds, duration - 0.2) : seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
        tap?.noteSeek()
    }

    func skip(by seconds: Double) { seek(to: currentTime + seconds) }

    /// Plays the marked part from a moment before it, stopping at its end.
    func preview() {
        guard let start, let end, let player else { return }
        seek(to: max(0, start - 1))
        previewEnd = end
        player.play()
    }

    // MARK: Marking

    func markStart() {
        start = currentTime
        if let end, end <= currentTime + Self.minimumLength { self.end = nil }
    }

    func markEnd() {
        end = currentTime
        if let start, start >= currentTime - Self.minimumLength { self.start = nil }
    }

    func nudgeStart(by amount: Double) {
        guard let value = start else { return }
        start = clamp(value + amount)
        seek(to: start ?? value)
    }

    func nudgeEnd(by amount: Double) {
        guard let value = end else { return }
        end = clamp(value + amount)
        seek(to: end ?? value)
    }

    private func clamp(_ value: Double) -> Double {
        max(0, duration > 0 ? min(value, duration) : value)
    }

    var length: Double? {
        guard let start, let end else { return nil }
        return end - start
    }

    /// Why the marked part can't be saved yet, if it can't.
    var markProblem: String? {
        guard start != nil else { return "Set where the part starts." }
        guard end != nil else { return "Set where the part ends." }
        guard let length else { return nil }
        if length < Self.minimumLength { return "Make it at least \(Int(Self.minimumLength)) seconds long." }
        if length > Self.maximumLength { return "Keep it under \(Int(Self.maximumLength / 60)) minutes." }
        return nil
    }

    // MARK: Capture

    struct Capture: Equatable {
        var picture: Bool
        var sound: Bool
    }

    /// What's already fingerprinted for the marked part.
    func capture() -> Capture {
        _ = captureRevision
        guard let start, let end, end > start else { return Capture(picture: false, sound: false) }
        return Capture(picture: timeline.visualCoverage(from: start, to: end) >= 0.85,
                       sound: audioPossible && timeline.audioRun(from: start, to: end) != nil)
    }

    func isCaptured(for method: DetectionMethod) -> Bool {
        guard let start, let end else { return false }
        return timeline.isCaptured(from: start, to: end, method: method, audioPossible: audioPossible)
    }

    /// Downloads just the marked part's segment files and fingerprints its
    /// picture and sound, without playing anything. A 90-second intro
    /// takes a few seconds. False if this stream can't be read directly.
    func readDirectly(method: DetectionMethod) async -> Bool {
        guard let reader, let start, let end, end > start else { return false }
        recordingCancelled = false
        recordingProgress = 0
        defer {
            recordingProgress = nil
            captureRevision += 1
        }
        do {
            if method.usesAudio {
                let chunks = try await reader.audio(from: max(0, start - 3), to: end + 1)
                guard !recordingCancelled else { return false }
                let fingerprinter = AudioFingerprinter()
                for chunk in chunks {
                    timeline.add(fingerprinter.append(chunk.samples, startTime: chunk.start, inputRate: chunk.rate))
                }
                recordingProgress = method.usesVisual ? 0.3 : 1
            }
            if method.usesVisual {
                let base = method.usesAudio ? 0.3 : 0
                let samples = try await reader.visualSamples(from: max(0, start - 0.5), to: end + 0.5) { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.recordingProgress != nil else { return }
                        self.recordingProgress = base + (1 - base) * fraction
                    }
                }
                guard !recordingCancelled else { return false }
                for sample in samples { timeline.add(sample) }
            }
            directFailure = nil
            return isCaptured(for: method)
        } catch {
            directFailure = error.localizedDescription
            return false
        }
    }

    /// Plays the marked part once so its picture is fingerprinted: the
    /// fallback for streams Vela can't read directly. False if it was
    /// cancelled or the stream stalled.
    func record() async -> Bool {
        guard let player, let start, let end, end > start else { return false }
        recordingCancelled = false
        previewEnd = nil
        recordingProgress = 0
        // A little run-up, so sound is already flowing at the start.
        seek(to: max(0, start - 1.5))
        player.play()
        let deadline = Date().addingTimeInterval((end - start) * 2 + 30)
        var finished = false
        while !recordingCancelled, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            guard self.player === player else { break }
            recordingProgress = min(1, max(0, (currentTime - start) / (end - start)))
            if currentTime >= end + 0.4 { finished = true; break }
            if player.rate == 0, player.timeControlStatus == .paused { player.play() }
        }
        player.pause()
        recordingProgress = nil
        captureRevision += 1
        return finished
    }

    func cancelRecording() {
        recordingCancelled = true
    }

    func makePrint() -> SegmentPrint? {
        guard let start, let end, end > start else { return nil }
        return timeline.print(from: start, to: end)
    }
}
