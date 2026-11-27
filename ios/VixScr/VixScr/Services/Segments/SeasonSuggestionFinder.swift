import Foundation
import Observation

/// After a segment is recorded for one season, looks for the same part in
/// the other seasons' first episodes, reading them straight from the
/// stream. What it finds becomes a suggestion (an orange warning on that
/// season) that the viewer checks and saves; it's never used by itself.
@MainActor
@Observable
final class SeasonSuggestionFinder {
    static let shared = SeasonSuggestionFinder()

    /// "titleKey|season" being searched.
    private(set) var scanning: Set<String> = []
    @ObservationIgnored private var queues: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var waiting: [String: [(RecordedSegment, Int)]] = [:]

    /// Longest stretch of an episode searched for one segment.
    private static let searchSpan: Double = 15 * 60
    /// Episodes tried per season.
    private static let episodesPerSeason = 2

    func isScanning(titleKey: String, season: Int) -> Bool {
        scanning.contains("\(titleKey)|\(season)")
    }

    /// Queues a search of every other season without a segment (or
    /// suggestion) of this name. Seasons are searched one at a time.
    func findOthers(for segment: RecordedSegment, from season: Int, only: Int? = nil, context: TitleContext, store: AppStore) {
        guard SegmentLibrary.exists(segment.id) else { return }
        let name = segment.name.lowercased()
        let skipping = store.titleSettings[context.key]?.skipping
        let targets = context.seasons.filter { target in
            target != season && (only == nil || only == target) &&
                skipping?.segments(season: target).contains { $0.name.lowercased() == name } != true &&
                skipping?.suggestions(season: target).contains { $0.name.lowercased() == name } != true
        }
        guard !targets.isEmpty else { return }
        for target in targets {
            waiting[context.key, default: []].append((segment, target))
            scanning.insert("\(context.key)|\(target)")
        }
        guard queues[context.key] == nil else { return }
        queues[context.key] = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, var list = self.waiting[context.key], !list.isEmpty {
                let (segment, target) = list.removeFirst()
                self.waiting[context.key] = list
                if let found = await Self.search(segment: segment, season: target, context: context) {
                    store.addSegmentSuggestion(found, titleKey: context.key, season: target)
                }
                if !(self.waiting[context.key] ?? []).contains(where: { $0.1 == target }) {
                    self.scanning.remove("\(context.key)|\(target)")
                }
            }
            self?.queues[context.key] = nil
            self?.waiting[context.key] = nil
        }
    }

    // MARK: Searching

    private static func search(segment: RecordedSegment, season: Int, context: TitleContext) async -> SegmentSuggestion? {
        guard let print = SegmentLibrary.load(segment.id) else { return nil }
        let episodes = await context.loadEpisodes(season)
        for episode in episodes.prefix(episodesPerSeason) {
            guard !Task.isCancelled, let stream = await context.resolveStream(episode) else { continue }
            let reader = HLSStreamReader(url: stream.url, requestHeaders: stream.requestHeaders, cookies: stream.httpCookies)
            guard let length = try? await reader.loadDuration(), length > 0 else { continue }
            // Search the same end of the episode the segment came from.
            let sourceLength = segment.matches[segment.sourceKey]?.videoDuration ?? length
            let nearEnd = sourceLength > 0 && segment.sourceStart > sourceLength / 2
            let range: ClosedRange<Double>
            if nearEnd {
                let fromEnd = max(0, sourceLength - segment.sourceStart)
                let lower = max(0, length - fromEnd - 300)
                range = max(lower, length - searchSpan)...length
            } else {
                range = 0...min(length, max(segment.sourceStart + segment.duration + 360, 240), searchSpan)
            }
            if let start = await find(print: print, segment: segment, in: range, reader: reader) {
                return SegmentSuggestion(sourceID: segment.id, name: segment.name, episodeKey: episode.id,
                                         episodeLabel: episode.label, start: max(0, start), duration: segment.duration,
                                         detection: segment.detection, matchConfidence: segment.matchConfidence)
            }
        }
        return nil
    }

    /// Sound when the segment has it (a few MB), otherwise the picture.
    private static func find(print: SegmentPrint, segment: RecordedSegment, in range: ClosedRange<Double>,
                             reader: HLSStreamReader) async -> Double? {
        let step = 30.0
        if segment.hasAudio, var matcher = AudioMatcher(print: print, confidence: segment.matchConfidence) {
            let fingerprinter = AudioFingerprinter()
            var cursor = range.lowerBound
            while cursor < range.upperBound, !Task.isCancelled {
                guard let chunks = try? await reader.audio(from: cursor, to: cursor + step) else { return nil }
                for chunk in chunks {
                    let codes = fingerprinter.append(chunk.samples, startTime: chunk.start, inputRate: chunk.rate)
                    if let start = matcher.add(codes) { return start }
                }
                let reach = chunks.last?.playlistEnd ?? 0
                cursor = reach > cursor ? reach : ((try? await reader.audioSegmentsEnd(from: cursor, to: cursor + step)) ?? cursor + step)
            }
            return nil
        }
        if segment.hasVisual, var matcher = VisualMatcher(print: print, confidence: segment.matchConfidence) {
            var cursor = range.lowerBound
            while cursor < range.upperBound, !Task.isCancelled {
                guard let samples = try? await reader.visualSamples(from: cursor, to: cursor + step) else { return nil }
                for sample in samples where sample.time >= cursor {
                    if let start = matcher.add(sample) { return start }
                }
                cursor += step
            }
        }
        return nil
    }
}
