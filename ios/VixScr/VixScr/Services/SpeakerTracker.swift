import Foundation
@preconcurrency import FluidAudio

/// Which speaker model splits auto captions, chosen in Settings ›
/// Playback › Speaker Model. All three are NVIDIA's Sortformer; they
/// differ in how much recent sound they compare a voice against.
enum SpeakerModelChoice: String, CaseIterable, Identifiable, Sendable {
    case off, fast, balanced, highContext

    var id: String { rawValue }
    static let key = "vela_caption_speaker_model"
    static let precisionKey = "vela_caption_speaker_precision"

    var title: String {
        switch self {
        case .off: "Off"
        case .fast: "Fast"
        case .balanced: "Balanced"
        case .highContext: "High Context"
        }
    }

    var detail: String {
        switch self {
        case .off: "Auto captions aren't split by speaker."
        case .fast: "About 3 seconds of recent sound. Lightest, least steady on voices it's just heard."
        case .balanced: "About 15 seconds of recent sound. Steadier, still no wait after a seek."
        case .highContext: "Reads about 30 seconds ahead. Steadiest, but after a seek there are no speaker splits for about 30 seconds."
        }
    }

    /// The saved choice; the older on/off switch maps to Off or Balanced.
    static var current: SpeakerModelChoice {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: key), let choice = SpeakerModelChoice(rawValue: raw) { return choice }
        if defaults.object(forKey: "vela_caption_speakers") as? Bool == false { return .off }
        return .balanced
    }

    static var compressed: Bool {
        UserDefaults.standard.string(forKey: precisionKey) == "compressed"
    }

    var config: SortformerConfig? {
        switch self {
        case .off: nil
        case .fast: .fastV2_1
        case .balanced: .balancedV2_1
        case .highContext: .highContextV2_1
        }
    }

    /// Full-precision High Context needs about 2.4 GB of memory.
    static var deviceFitsFullHighContext: Bool {
        ProcessInfo.processInfo.physicalMemory >= 7_500_000_000
    }
}

/// Where Vela keeps downloaded models, one folder each, so Settings ›
/// Models can list and delete them.
enum ModelStore {
    static var root: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Vela/Models", isDirectory: true)
    }

    static func speakerFolder(_ choice: SpeakerModelChoice, compressed: Bool) -> URL {
        root.appendingPathComponent("Speakers-\(choice.rawValue)-\(compressed ? "compressed" : "full")", isDirectory: true)
    }

    /// Where the first speaker build downloaded to, before Vela had its own folder.
    static var legacyFolder: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }

    struct Entry: Identifiable {
        let id: URL
        let title: String
        let detail: String
        let bytes: Int64
        let inUse: Bool
    }

    static func entries() -> [Entry] {
        var out: [Entry] = []
        let current = SpeakerModelChoice.current
        let compressed = SpeakerModelChoice.compressed
        for choice in SpeakerModelChoice.allCases where choice != .off {
            for squeeze in [false, true] {
                let folder = speakerFolder(choice, compressed: squeeze)
                let bytes = size(of: folder)
                guard bytes > 0 else { continue }
                out.append(Entry(id: folder, title: "Speaker model: \(choice.title)",
                                 detail: squeeze ? "Compressed" : "Full precision", bytes: bytes,
                                 inUse: choice == current && squeeze == compressed))
            }
        }
        let legacy = size(of: legacyFolder)
        if legacy > 0 {
            out.append(Entry(id: legacyFolder, title: "Speaker model: earlier download",
                             detail: "From a previous Vela build", bytes: legacy, inUse: false))
        }
        return out
    }

    static func delete(_ entry: Entry) {
        try? FileManager.default.removeItem(at: entry.id)
    }

    static func size(of folder: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }
}

/// Who is speaking when, for auto captions, from the Sortformer model run on
/// the phone through FluidAudio. It hears that voices differ, not who they
/// are, and tracks up to four at a time (slots are reused as voices leave).
///
/// Only finalised turns are used: FluidAudio closes a turn when that voice
/// stops, and its provisional half-second guesses at the end of each update
/// were what flipped lines to the wrong speaker mid-sentence. Turns shorter
/// than 0.3 s (breaths, laughs, music bursts) are dropped.
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

    private let model: SpeakerModel
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

    private static let shortestTurn = 0.3

    init?(choice: SpeakerModelChoice, compressed: Bool) {
        guard var config = choice.config else { return nil }
        // Full-precision High Context doesn't fit in this phone's memory.
        let squeeze = compressed || (choice == .highContext && !SpeakerModelChoice.deviceFitsFullHighContext)
        config.precision = squeeze ? .palettized : .fp16
        model = SpeakerModel(config: config, folder: ModelStore.speakerFolder(choice, compressed: squeeze))
    }

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

    /// The speaker heard most during `start...end`, and the share of that
    /// stretch they cover, if the model has reached it.
    func speaker(from start: Double, to end: Double) -> (speaker: Int, share: Double)? {
        var overlap: [Int: Double] = [:]
        // Finalised turns are in time order: search back from the newest.
        for turn in finalized.reversed() {
            if turn.end < start - 60 { break }
            guard turn.end > start, turn.start < end else { continue }
            overlap[turn.speaker, default: 0] += min(end, turn.end) - max(start, turn.start)
        }
        guard let best = overlap.max(by: { $0.value < $1.value }) else { return nil }
        return (best.key, best.value / max(0.05, end - start))
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

    private func apply(_ turns: [Turn]) {
        let mapped = turns.compactMap(map).filter { $0.end - $0.start >= Self.shortestTurn }
        guard let earliest = mapped.map(\.start).min() else { return }
        finalized.append(contentsOf: mapped)
        finalized.sort { $0.start < $1.start }
        if finalized.count > 6_000 { finalized.removeFirst(finalized.count - 6_000) }
        onChange?(earliest)
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
    private let config: SortformerConfig
    private let folder: URL
    private var diarizer: SortformerDiarizer?

    init(config: SortformerConfig, folder: URL) {
        self.config = config
        self.folder = folder
    }

    func load() async throws {
        guard diarizer == nil else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let models = try await SortformerModels.loadFromHuggingFace(config: config, cacheDirectory: folder)
        let diarizer = SortformerDiarizer(config: config)
        diarizer.initialize(models: models)
        self.diarizer = diarizer
    }

    /// Newly finalised turns, in seconds on the model's own clock.
    func process(_ samples: [Float], rate: Double) throws -> [SpeakerTracker.Turn] {
        guard let diarizer, let update = try diarizer.process(samples: samples, sourceSampleRate: rate) else { return [] }
        return update.finalizedSegments.map {
            SpeakerTracker.Turn(start: Double($0.startTime), end: Double($0.endTime), speaker: $0.speakerIndex)
        }
    }

    func close() {
        diarizer?.cleanup()
        diarizer = nil
    }
}
