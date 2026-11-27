import AVFoundation
import CoreMedia
import Foundation
import Speech

/// iOS 26's SpeechAnalyzer / SpeechTranscriber, fed the episode's sound as
/// one continuous stream. It's Apple's long-form model (Notes, Voice Memos):
/// it keeps context across sentences and has no clip edges.
///
/// One session lasts the whole episode, seeks included. The analyzer only
/// sees its own clock, which always moves forward; every chunk records
/// where it landed on that clock and where it is in the episode
/// ("anchors"), so results map back to the right playback time wherever
/// the viewer jumped. A jump puts a short silence in between so words on
/// either side aren't run together. Starting a new session on every seek
/// is what used to leave captions blank after skipping back.
@available(iOS 26.0, *)
@MainActor
final class LongFormTranscriber {
    struct Word: Sendable {
        let start: Double
        let end: Double
        let text: String
    }

    /// (words, start, end, isFinal). Rough words come first and are
    /// replaced by final ones for the same stretch.
    private let onWords: ([Word], Double, Double, Bool) -> Void
    private let onStatus: (String) -> Void

    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var ready = false
    private var stopped = false
    private var waiting: [AudioChunk] = []

    private var anchors: [(session: Double, playback: Double)] = []
    private var fed = 0.0
    private var expectedNext: Double?
    /// Episode time already sent, merged into ranges.
    private(set) var covered: [ClosedRange<Double>] = []
    /// Furthest episode time any result (rough or final) has reached.
    private(set) var heardUntil: Double?

    init(onWords: @escaping ([Word], Double, Double, Bool) -> Void, onStatus: @escaping (String) -> Void) {
        self.onWords = onWords
        self.onStatus = onStatus
    }

    /// Opens the session, downloading the language model once if needed.
    /// Throws when the language isn't supported on this device.
    func start(locale requested: Locale, vocabulary: [String]) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw AutoCaptionEngine.Failure.unavailable
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults],
                                            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onStatus("Downloading the speech model (once)…")
            try await request.downloadAndInstall()
        }
        guard !stopped else { return }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(vocabulary.prefix(100))
            try? await analyzer.setContext(context)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AutoCaptionEngine.Failure.audioFormat
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, !self.stopped else { return }
                    self.handle(result.text, isFinal: result.isFinal)
                }
            } catch {
                guard let self, !self.stopped else { return }
                self.onStatus("Speech recognition stopped: \(error.localizedDescription)")
            }
        }
        try await analyzer.start(inputSequence: stream)
        guard !stopped else {
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            return
        }
        self.analyzer = analyzer
        self.input = continuation
        self.format = format
        ready = true
        let queued = waiting
        waiting = []
        for chunk in queued { feed(chunk) }
    }

    func stop() {
        stopped = true
        ready = false
        waiting = []
        input?.finish()
        input = nil
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
    }

    // MARK: Coverage

    /// The part of `chunk` not sent yet, or nil if all of it was.
    func unsent(_ chunk: AudioChunk) -> AudioChunk? {
        guard let range = covered.first(where: { $0.contains(chunk.start + 0.05) }) else { return chunk }
        let skip = range.upperBound - chunk.start
        guard skip < chunk.duration - 0.05 else { return nil }
        let drop = min(chunk.samples.count, Int(skip * chunk.rate))
        var stereo: StereoSamples?
        if let s = chunk.stereo {
            stereo = StereoSamples(left: Array(s.left.dropFirst(drop)), right: Array(s.right.dropFirst(drop)))
        }
        return AudioChunk(start: chunk.start + Double(drop) / chunk.rate, rate: chunk.rate,
                          samples: Array(chunk.samples.dropFirst(drop)), playlistEnd: chunk.playlistEnd, stereo: stereo)
    }

    private func cover(_ range: ClosedRange<Double>) {
        var merged = range
        covered.removeAll { other in
            guard other.lowerBound <= merged.upperBound + 0.1, other.upperBound >= merged.lowerBound - 0.1 else { return false }
            merged = min(other.lowerBound, merged.lowerBound)...max(other.upperBound, merged.upperBound)
            return true
        }
        covered.append(merged)
        covered.sort { $0.lowerBound < $1.lowerBound }
    }

    /// How far past `time` sound has been sent without a gap.
    func sentAhead(of time: Double) -> Double {
        covered.first { $0.contains(time) }.map { $0.upperBound - time } ?? 0
    }

    // MARK: Audio

    func feed(_ chunk: AudioChunk) {
        guard !stopped else { return }
        guard ready else {
            waiting.append(chunk)
            if waiting.count > 30 { waiting.removeFirst() }
            return
        }
        var samples = chunk.samples
        var start = chunk.start
        if let expected = expectedNext {
            let gap = start - expected
            if gap < -0.01 && gap > -0.6 {
                // Slight overlap with what was sent: skip the repeat.
                samples.removeFirst(min(samples.count, Int(-gap * chunk.rate)))
                start = expected
            } else if abs(gap) > 0.15 {
                // A jump: a short silence so words either side aren't joined.
                if let silence = convert([Float](repeating: 0, count: Int(0.8 * chunk.rate)), rate: chunk.rate) {
                    input?.yield(AnalyzerInput(buffer: silence))
                    fed += 0.8
                }
            }
        }
        guard !samples.isEmpty, let buffer = convert(samples, rate: chunk.rate) else { return }
        let length = Double(samples.count) / chunk.rate
        anchors.append((fed, start))
        if anchors.count > 2_000 { anchors.removeFirst(anchors.count - 2_000) }
        fed += length
        expectedNext = start + length
        cover(start...(start + length))
        input?.yield(AnalyzerInput(buffer: buffer))
    }

    private func convert(_ samples: [Float], rate: Double) -> AVAudioPCMBuffer? {
        guard let format,
              let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = source.floatChannelData?[0] else { return nil }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        if sourceFormat == format { return source }
        if converter == nil || converterInput != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: format)
            converterInput = sourceFormat
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(samples.count) * format.sampleRate / rate) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var handed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if handed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            handed = true
            inputStatus.pointee = .haveData
            return source
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    // MARK: Results

    /// Session time → episode time, through the chunk it fell in. Nil for
    /// the silences put in at jumps.
    private func playbackTime(_ session: Double) -> Double? {
        guard !anchors.isEmpty, session >= anchors[0].session - 0.5 else { return nil }
        var low = 0, high = anchors.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if anchors[mid].session <= session { low = mid } else { high = mid - 1 }
        }
        return anchors[low].playback + max(0, session - anchors[low].session)
    }

    private func handle(_ text: AttributedString, isFinal: Bool) {
        var words: [Word] = []
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let piece = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty, let start = playbackTime(range.start.seconds),
                  let end = playbackTime(range.end.seconds), end >= start, end - start < 8 else { continue }
            // The first word after a pause takes the pause into its own
            // range, which shows the line early; pull long ones in.
            let adjusted = end - start > 0.7 ? end - 0.35 : start
            words.append(Word(start: adjusted, end: end, text: piece))
        }
        guard let first = words.first, let last = words.last else { return }
        heardUntil = max(heardUntil ?? last.end, last.end)
        onWords(words, first.start, last.end, isFinal)
    }
}
