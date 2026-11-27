import AVFoundation
import CoreMedia
import Foundation
import QuartzCore

/// Reads what an `AVPlayerItem` is showing and playing, without changing
/// playback, and turns it into fingerprints:
///   - picture: an `AVPlayerItemVideoOutput` sampled four times a second
///     (every iOS version Vela runs on);
///   - sound: the iOS 27 decoded-audio output, the same source on-device
///     captions use.
/// Used by the segment recorder and by live segment detection.
@MainActor
final class PlaybackFeatureTap {
    var onVisual: ((VisualSample) -> Void)?
    var onAudio: (([AudioCode]) -> Void)?

    static var canReadAudio: Bool {
        if #available(iOS 27.0, *) { return true }
        return false
    }

    private weak var item: AVPlayerItem?
    private let wantsVisual: Bool
    private let wantsAudio: Bool
    private let playbackTime: () -> Double
    private var videoOutput: AVPlayerItemVideoOutput?
    private var videoTask: Task<Void, Never>?
    private var audioTap: AnyObject?

    init(item: AVPlayerItem, visual: Bool, audio: Bool, playbackTime: @escaping () -> Double) {
        self.item = item
        self.wantsVisual = visual
        self.wantsAudio = audio && Self.canReadAudio
        self.playbackTime = playbackTime
    }

    /// Audio fingerprints are coming in.
    var isReceivingAudio: Bool {
        if #available(iOS 27.0, *), let tap = audioTap as? AudioFeatureTap { return tap.bufferCount > 0 }
        return false
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
        if wantsAudio, audioTap == nil {
            if #available(iOS 27.0, *) {
                let tap = AudioFeatureTap(item: item, playbackTime: playbackTime) { [weak self] codes in
                    self?.onAudio?(codes)
                }
                tap?.start()
                audioTap = tap
            }
        }
    }

    func stop() {
        videoTask?.cancel()
        videoTask = nil
        if let videoOutput, let item { item.remove(videoOutput) }
        videoOutput = nil
        if #available(iOS 27.0, *) { (audioTap as? AudioFeatureTap)?.stop() }
        audioTap = nil
    }

    /// The playhead jumped: sound fingerprints restart from the new place.
    func noteSeek() {
        if #available(iOS 27.0, *) { (audioTap as? AudioFeatureTap)?.noteSeek() }
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

/// Decoded audio from the iOS 27 sample-buffer output, turned into audio
/// codes. Timeline handling follows `AutoCaptionEngine`: HLS audio
/// timestamps can sit on a different timeline than the player's, so the
/// first buffer (and the first after a seek) calibrates the offset.
@available(iOS 27.0, *)
@MainActor
final class AudioFeatureTap {
    private weak var item: AVPlayerItem?
    private let output: AVPlayerItemSampleBufferOutput
    private let playbackTime: () -> Double
    private let onCodes: ([AudioCode]) -> Void
    private let fingerprinter = AudioFingerprinter()
    private var pullTask: Task<Void, Never>?
    private var timelineOffset = 0.0
    private var calibrated = false
    private var seekPending = false
    private(set) var bufferCount = 0

    init?(item: AVPlayerItem, playbackTime: @escaping () -> Double, onCodes: @escaping ([AudioCode]) -> Void) {
        guard let pcm = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else { return nil }
        var asbd = pcm.streamDescription.pointee
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                             layoutSize: 0, layout: nil, magicCookieSize: 0,
                                             magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &description) == noErr,
              let description else { return nil }
        let configuration = AVPlayerItemSampleBufferOutputAudioConfiguration()
        configuration.requestedAudioFormat = description
        output = AVPlayerItemSampleBufferOutput(configuration: configuration)
        self.item = item
        self.playbackTime = playbackTime
        self.onCodes = onCodes
    }

    func start() {
        guard pullTask == nil, let item else { return }
        item.add(output)
        let output = output
        pullTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, let next = await output.nextSampleBuffer() {
                guard let self else { return }
                let sample = next.sampleBuffer
                guard sample.sampleCount > 0 else { continue }
                let raw = sample.presentationTimeStamp.seconds
                guard raw.isFinite else { continue }
                self.bufferCount += 1

                if next.sequenceWasRestarted || self.seekPending {
                    self.calibrated = false
                    self.seekPending = false
                    self.fingerprinter.reset()
                }
                if !self.calibrated {
                    let delta = self.playbackTime() - raw
                    self.timelineOffset = abs(delta) > 2 ? delta : 0
                    self.calibrated = true
                }
                let timestamp = raw + self.timelineOffset

                // Stay close to the picture, like the caption engine, so a
                // long read-ahead can't run the fingerprints far ahead.
                let started = self.playbackTime()
                while !Task.isCancelled, timestamp > self.playbackTime() + 8 {
                    try? await Task.sleep(for: .milliseconds(200))
                    if self.playbackTime() < started - 1.5 { break }
                }
                guard !Task.isCancelled else { break }
                if self.playbackTime() < started - 1.5 {
                    self.fingerprinter.reset()
                    continue
                }

                let decoded = sample.withUnsafeSampleBuffer { buffer in Self.monoSamples(buffer) }
                let codes = self.fingerprinter.append(decoded.samples, startTime: timestamp, inputRate: decoded.rate)
                if !codes.isEmpty { self.onCodes(codes) }
            }
        }
    }

    func noteSeek() {
        seekPending = true
        fingerprinter.reset()
    }

    func stop() {
        pullTask?.cancel()
        pullTask = nil
        if let item { item.remove(output) }
        item = nil
    }

    /// The buffer's audio as mono floats, whatever layout iOS delivered.
    nonisolated private static func monoSamples(_ buffer: CMSampleBuffer) -> (samples: [Float], rate: Double) {
        guard let description = CMSampleBufferGetFormatDescription(buffer),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              let block = CMSampleBufferGetDataBuffer(buffer) else { return ([], 48_000) }
        let rate = format.mSampleRate > 0 ? format.mSampleRate : 48_000
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return ([], rate) }
        var bytes = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes) == kCMBlockBufferNoErr else { return ([], rate) }

        let channels = max(1, Int(format.mChannelsPerFrame))
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bytesPerSample = max(1, Int(format.mBitsPerChannel) / 8)
        // Interleaved: frames × channels samples. Non-interleaved: one plane
        // per channel, back to back; the first plane is enough.
        let frames = length / bytesPerSample / channels
        let stride = nonInterleaved ? 1 : channels

        let samples = bytes.withUnsafeBytes { raw -> [Float] in
            var out = [Float](repeating: 0, count: frames)
            if isFloat && bytesPerSample == 4 {
                let values = raw.bindMemory(to: Float.self)
                for f in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<stride { sum += values[f * stride + c] }
                    out[f] = sum / Float(stride)
                }
            } else if !isFloat && bytesPerSample == 2 {
                let values = raw.bindMemory(to: Int16.self)
                for f in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<stride { sum += Float(values[f * stride + c]) / 32_768 }
                    out[f] = sum / Float(stride)
                }
            } else {
                return []
            }
            return out
        }
        return (samples, rate)
    }
}

/// Live detection of the title's recorded segments in the playing item.
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

    init?(item: AVPlayerItem, targets: [Target], playbackTime: @escaping () -> Double,
          onMatch: @escaping (UUID, Double) -> Void) {
        var visualMatchers: [UUID: VisualMatcher] = [:]
        var audioMatchers: [UUID: AudioMatcher] = [:]
        var pending: Set<UUID> = []
        for target in targets {
            guard let method = target.segment.effectiveDetection else { continue }
            var usable = false
            if method.usesVisual, let matcher = VisualMatcher(print: target.print) {
                visualMatchers[target.segment.id] = matcher
                usable = true
            }
            if method.usesAudio, PlaybackFeatureTap.canReadAudio, let matcher = AudioMatcher(print: target.print) {
                audioMatchers[target.segment.id] = matcher
                usable = true
            }
            if usable { pending.insert(target.segment.id) }
        }
        guard !pending.isEmpty else { return nil }
        tap = PlaybackFeatureTap(item: item, visual: !visualMatchers.isEmpty, audio: !audioMatchers.isEmpty,
                                 playbackTime: playbackTime)
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
