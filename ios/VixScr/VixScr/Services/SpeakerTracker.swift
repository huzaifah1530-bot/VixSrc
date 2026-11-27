import Foundation
@preconcurrency import FluidAudio

/// Who is speaking when, for auto captions: NVIDIA's Sortformer speaker
/// model, run on the phone through FluidAudio. It hears that voices differ,
/// not who they are, and tracks up to four at a time. Captions use it to
/// start a new line when the speaker changes, and to put an em dash before
/// each speaker when two share the screen.
@MainActor
final class SpeakerTracker {
    struct Turn: Sendable {
        let start: Double
        let end: Double
        let speaker: Int
    }

    /// New speaker turns arrived from this episode time on.
    var onChange: ((Double) -> Void)?
    var onStatus: ((String) -> Void)?

    private let model = SpeakerModel()
    private var ready = false
    private var failed = false
    private var working = false
    private var stopped = false
    private var queue: [AudioChunk] = []

    /// Same idea as the transcriber's anchors: the model's own clock always
    /// moves forward, and each chunk records where it is in the episode.
    private var anchors: [(model: Double, playback: Double)] = []
    private var fed = 0.0
    private var expectedNext: Double?
    private var finalized: [Turn] = []
    private var tentative: [Turn] = []

    func start() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.onStatus?("Loading the speaker model (downloads once)…")
                try await self.model.load()
                guard !self.stopped else { return }
                self.ready = true
                self.onStatus?("")
                self.pump()
            } catch {
                self.failed = true
                self.queue = []
                self.onStatus?("")
            }
        }
    }

    func stop() {
        stopped = true
        queue = []
        let model = model
        Task { await model.close() }
    }

    func feed(_ chunk: AudioChunk) {
        guard !failed, !stopped, !chunk.samples.isEmpty else { return }
        queue.append(chunk)
        if queue.count > 40 { queue.removeFirst(queue.count - 40) }
        pump()
    }

    // MARK: Lookup

    /// The speaker heard most during `start...end`, if the model has
    /// reached that stretch.
    func speaker(from start: Double, to end: Double) -> Int? {
        var best: (speaker: Int, overlap: Double)?
        for turn in finalized.reversed() + tentative where turn.end > start && turn.start < end {
            let overlap = min(end, turn.end) - max(start, turn.start)
            if overlap > (best?.overlap ?? 0) { best = (turn.speaker, overlap) }
        }
        return best?.speaker
    }

    // MARK: Processing

    private func pump() {
        guard ready, !working, !stopped, !queue.isEmpty else { return }
        working = true
        let chunk = queue.removeFirst()
        var samples = chunk.samples
        var start = chunk.start
        var silence = 0.0
        if let expected = expectedNext {
            let gap = start - expected
            if gap < -0.01 && gap > -0.6 {
                samples.removeFirst(min(samples.count, Int(-gap * chunk.rate)))
                start = expected
            } else if abs(gap) > 0.15 {
                // A jump: a pause so the two sides aren't heard as one turn.
                silence = 0.8
            }
        }
        guard !samples.isEmpty else { working = false; pump(); return }
        let audio = silence > 0 ? [Float](repeating: 0, count: Int(silence * chunk.rate)) + samples : samples
        anchors.append((fed + silence, start))
        if anchors.count > 2_000 { anchors.removeFirst(anchors.count - 2_000) }
        let length = Double(samples.count) / chunk.rate
        fed += silence + length
        expectedNext = start + length
        let rate = chunk.rate
        let model = model
        Task { @MainActor [weak self] in
            let result = try? await model.process(audio, rate: rate)
            guard let self, !self.stopped else { return }
            if let result { self.apply(result) }
            self.working = false
            self.pump()
        }
    }

    private func apply(_ result: SpeakerModel.Update) {
        let mapped = result.finalized.compactMap(map)
        finalized.append(contentsOf: mapped)
        if finalized.count > 6_000 { finalized.removeFirst(finalized.count - 6_000) }
        tentative = result.tentative.compactMap(map)
        if let earliest = (mapped + tentative).map(\.start).min() { onChange?(earliest) }
    }

    private func map(_ turn: Turn) -> Turn? {
        guard let start = playbackTime(turn.start), let end = playbackTime(turn.end), end > start else { return nil }
        return Turn(start: start, end: end, speaker: turn.speaker)
    }

    private func playbackTime(_ time: Double) -> Double? {
        guard !anchors.isEmpty, time >= anchors[0].model - 0.5 else { return nil }
        var low = 0, high = anchors.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if anchors[mid].model <= time { low = mid } else { high = mid - 1 }
        }
        return anchors[low].playback + max(0, time - anchors[low].model)
    }
}

/// The FluidAudio diarizer, kept off the main thread.
actor SpeakerModel {
    struct Update: Sendable {
        let finalized: [SpeakerTracker.Turn]
        let tentative: [SpeakerTracker.Turn]
    }

    private var diarizer: SortformerDiarizer?

    func load() async throws {
        guard diarizer == nil else { return }
        let config = SortformerConfig.default
        let models = try await SortformerModels.loadFromHuggingFace(config: config)
        let diarizer = SortformerDiarizer(config: config)
        diarizer.initialize(models: models)
        self.diarizer = diarizer
    }

    /// Times are seconds on the model's own clock.
    func process(_ samples: [Float], rate: Double) throws -> Update? {
        guard let diarizer, let update = try diarizer.process(samples: samples, sourceSampleRate: rate) else { return nil }
        func turn(_ segment: DiarizerSegment) -> SpeakerTracker.Turn {
            SpeakerTracker.Turn(start: Double(segment.startTime), end: Double(segment.endTime), speaker: segment.speakerIndex)
        }
        return Update(finalized: update.finalizedSegments.map(turn), tentative: update.tentativeSegments.map(turn))
    }

    func close() {
        diarizer?.cleanup()
        diarizer = nil
    }
}
