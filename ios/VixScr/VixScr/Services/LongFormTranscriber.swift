import AVFoundation
import CoreMedia
import Foundation
import Speech

/// iOS 26's SpeechAnalyzer / SpeechTranscriber, fed the episode's sound as
/// one continuous stream. It's Apple's long-form model (Notes, Voice Memos):
/// it keeps context across sentences and has no clip edges, so lines aren't
/// cut in half or skipped the way 10-second SFSpeechRecognizer clips were.
@available(iOS 26.0, *)
@MainActor
final class LongFormTranscriber {
    struct Word: Sendable {
        let start: Double
        let end: Double
        let text: String
    }

    /// Final words on the playback timeline, with the span they cover.
    private let onWords: ([Word], Double, Double) -> Void
    private let onStatus: (String) -> Void

    private var locale: Locale?
    private var vocabulary: [String] = []
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var generation = 0
    private var ready = false
    private var waiting: [AudioChunk] = []

    /// Where each chunk landed: seconds fed to the analyzer → playback time.
    /// Results are mapped back through these, so small gaps between chunks
    /// never make captions drift.
    private var anchors: [(session: Double, playback: Double)] = []
    private var fed = 0.0
    private var expectedNext: Double?

    init(onWords: @escaping ([Word], Double, Double) -> Void, onStatus: @escaping (String) -> Void) {
        self.onWords = onWords
        self.onStatus = onStatus
    }

    /// The model's locale for `locale`, downloading it once if needed.
    /// Throws when the language isn't supported on this device.
    func start(locale requested: Locale, vocabulary: [String]) async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw AutoCaptionEngine.Failure.unavailable
        }
        let probe = Self.makeTranscriber(supported)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            onStatus("Downloading the speech model (once)…")
            try await request.downloadAndInstall()
        }
        locale = supported
        self.vocabulary = Array(vocabulary.prefix(100))
        try await openSession()
    }

    private static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                          attributeOptions: [.audioTimeRange])
    }

    private func openSession() async throws {
        guard let locale else { return }
        closeSession()
        generation += 1
        let generation = generation
        let transcriber = Self.makeTranscriber(locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try? await analyzer.setContext(context)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AutoCaptionEngine.Failure.audioFormat
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, generation == self.generation else { return }
                    self.handle(result.text)
                }
            } catch {
                guard let self, generation == self.generation else { return }
                self.onStatus("Speech recognition stopped: \(error.localizedDescription)")
            }
        }
        try await analyzer.start(inputSequence: stream)
        guard generation == self.generation else { return }
        self.analyzer = analyzer
        self.input = continuation
        self.format = format
        converter = nil
        converterInput = nil
        anchors = []
        fed = 0
        expectedNext = nil
        ready = true
        let queued = waiting
        waiting = []
        for chunk in queued { feed(chunk) }
    }

    private func closeSession() {
        ready = false
        input?.finish()
        input = nil
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
    }

    /// The playhead jumped: begin a fresh session there.
    func restart() {
        guard locale != nil else { return }
        waiting = []
        ready = false
        Task { @MainActor [weak self] in try? await self?.openSession() }
    }

    func stop() {
        generation += 1
        locale = nil
        waiting = []
        closeSession()
    }

    // MARK: Audio

    func feed(_ chunk: AudioChunk) {
        guard ready else {
            waiting.append(chunk)
            if waiting.count > 20 { waiting.removeFirst() }
            return
        }
        var samples = chunk.samples
        var start = chunk.start
        if let expected = expectedNext {
            let gap = start - expected
            if abs(gap) > 0.6 {
                // Not the next stretch of sound: start over from it.
                restart()
                waiting = [chunk]
                return
            }
            if gap < -0.01 {
                // Overlaps what was already sent: skip the repeat.
                let drop = min(samples.count, Int(-gap * chunk.rate))
                samples.removeFirst(drop)
                start = expected
            }
        }
        guard !samples.isEmpty, let buffer = convert(samples, rate: chunk.rate) else { return }
        anchors.append((fed, start))
        if anchors.count > 400 { anchors.removeFirst(anchors.count - 400) }
        fed += Double(samples.count) / chunk.rate
        expectedNext = start + Double(samples.count) / chunk.rate
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

    private func playbackTime(_ session: Double) -> Double? {
        guard !anchors.isEmpty else { return nil }
        var low = 0, high = anchors.count - 1
        if session < anchors[0].session { return anchors[0].playback - (anchors[0].session - session) }
        while low < high {
            let mid = (low + high + 1) / 2
            if anchors[mid].session <= session { low = mid } else { high = mid - 1 }
        }
        return anchors[low].playback + (session - anchors[low].session)
    }

    private func handle(_ text: AttributedString) {
        var words: [Word] = []
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let piece = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty, let start = playbackTime(range.start.seconds),
                  let end = playbackTime(range.end.seconds), end >= start else { continue }
            // The first word after a pause absorbs the pause into its own
            // range, which makes the line appear early. Words are rarely
            // longer than this, so pull long ones in to their end.
            let adjusted = end - start > 0.7 ? end - 0.35 : start
            words.append(Word(start: adjusted, end: end, text: piece))
        }
        guard let first = words.first, let last = words.last else { return }
        onWords(words, first.start, last.end)
    }
}
