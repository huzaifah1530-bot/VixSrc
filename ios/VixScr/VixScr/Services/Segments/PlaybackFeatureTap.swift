import AVFoundation
import CoreMedia
import Foundation
import QuartzCore

/// Fingerprints what's playing, without changing playback:
///   - picture: an `AVPlayerItemVideoOutput` sampled four times a second;
///   - sound: the stream's own audio, decoded by Vela (`HLSAudioFeed`),
///     which runs ahead of the playhead.
@MainActor
final class PlaybackFeatureTap {
    var onVisual: ((VisualSample) -> Void)?
    var onAudio: (([AudioCode]) -> Void)?

    /// Sound is read from the stream itself, on every iOS version.
    static var canReadAudio: Bool { true }

    private weak var item: AVPlayerItem?
    private let wantsVisual: Bool
    private let audioFeed: HLSAudioFeed?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var videoTask: Task<Void, Never>?
    private var audioListener: UUID?
    private let fingerprinter = AudioFingerprinter()

    init(item: AVPlayerItem, visual: Bool, audioFeed: HLSAudioFeed?) {
        self.item = item
        self.wantsVisual = visual
        self.audioFeed = audioFeed
    }

    func start() {
        guard let item else { return }
        if wantsVisual, videoOutput == nil {
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ])
            item.add(output)
            videoOutput = output
            videoTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, !Task.isCancelled else { return }
                    self.pollVideo()
                }
            }
        }
        if let audioFeed, audioListener == nil {
            audioListener = audioFeed.listen { [weak self] chunk in
                guard let self else { return }
                let codes = self.fingerprinter.append(chunk.samples, startTime: chunk.start, inputRate: chunk.rate)
                if !codes.isEmpty { self.onAudio?(codes) }
            }
        }
    }

    func stop() {
        videoTask?.cancel()
        videoTask = nil
        if let videoOutput, let item { item.remove(videoOutput) }
        videoOutput = nil
        if let audioListener { audioFeed?.stopListening(audioListener) }
        audioListener = nil
    }

    /// The playhead jumped. The feed restarts itself; a new run of sound
    /// begins a new fingerprint run.
    func noteSeek() {
        fingerprinter.reset()
    }

    private func pollVideo() {
        guard let output = videoOutput else { return }
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard itemTime.isValid, output.hasNewPixelBuffer(forItemTime: itemTime) else { return }
        var displayTime = CMTime.invalid
        guard let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayTime) else { return }
        let time = displayTime.isValid ? displayTime.seconds : itemTime.seconds
        if let sample = FrameHasher.sample(buffer, time: time) { onVisual?(sample) }
    }
}

/// Live detection of the title's recorded segments in the playing item.
/// Sound is matched ahead of the playhead, so a segment found by sound is
/// usually known before it plays.
@MainActor
final class SegmentDetector {
    struct Target {
        let segment: RecordedSegment
        let print: SegmentPrint
    }

    private var visual: [UUID: VisualMatcher] = [:]
    private var audio: [UUID: AudioMatcher] = [:]
    private let tap: PlaybackFeatureTap
    private let onMatch: (UUID, Double) -> Void
    /// Segments still being looked for.
    private(set) var searching: Set<UUID> = []

    init?(item: AVPlayerItem, targets: [Target], audioFeed: HLSAudioFeed?,
          onMatch: @escaping (UUID, Double) -> Void) {
        var visualMatchers: [UUID: VisualMatcher] = [:]
        var audioMatchers: [UUID: AudioMatcher] = [:]
        var pending: Set<UUID> = []
        for target in targets {
            guard let method = target.segment.effectiveDetection else { continue }
            let confidence = target.segment.matchConfidence
            var usable = false
            if method.usesVisual, let matcher = VisualMatcher(print: target.print, confidence: confidence) {
                visualMatchers[target.segment.id] = matcher
                usable = true
            }
            if method.usesAudio, audioFeed != nil, let matcher = AudioMatcher(print: target.print, confidence: confidence) {
                audioMatchers[target.segment.id] = matcher
                usable = true
            }
            if usable { pending.insert(target.segment.id) }
        }
        guard !pending.isEmpty else { return nil }
        tap = PlaybackFeatureTap(item: item, visual: !visualMatchers.isEmpty,
                                 audioFeed: audioMatchers.isEmpty ? nil : audioFeed)
        self.onMatch = onMatch
        visual = visualMatchers
        audio = audioMatchers
        searching = pending
        tap.onVisual = { [weak self] sample in self?.handle(sample) }
        tap.onAudio = { [weak self] codes in self?.handle(codes) }
        tap.start()
    }

    func noteSeek() {
        tap.noteSeek()
        for id in visual.keys { visual[id]?.reset() }
        for id in audio.keys { audio[id]?.reset() }
    }

    func stop() {
        tap.stop()
        visual.removeAll()
        audio.removeAll()
        searching.removeAll()
    }

    private func handle(_ sample: VisualSample) {
        for id in Array(visual.keys) {
            guard var matcher = visual[id] else { continue }
            let found = matcher.add(sample)
            visual[id] = matcher
            if let found { resolve(id, start: found) }
        }
    }

    private func handle(_ codes: [AudioCode]) {
        for id in Array(audio.keys) {
            guard var matcher = audio[id] else { continue }
            let found = matcher.add(codes)
            audio[id] = matcher
            if let found { resolve(id, start: found) }
        }
    }

    private func resolve(_ id: UUID, start: Double) {
        guard searching.remove(id) != nil else { return }
        visual[id] = nil
        audio[id] = nil
        onMatch(id, start)
        if searching.isEmpty { tap.stop() }
    }
}
