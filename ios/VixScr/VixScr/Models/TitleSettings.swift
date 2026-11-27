import Foundation

/// What a title is, for the per-title settings page. Decides the page's name
/// ("Show Settings"), whether segments are recorded from an episode, and
/// whether "audio" means a Sub / Dub source or an audio-track language.
enum TitleKind: String, Codable, Sendable {
    case movie, show, anime

    init(item: MediaItem) {
        if item.isAnime || item.isAnimeCatalog {
            self = .anime
        } else {
            self = item.type == .movie ? .movie : .show
        }
    }

    var noun: String {
        switch self {
        case .movie: "Movie"
        case .show: "Show"
        case .anime: "Anime"
        }
    }

    var settingsTitle: String { "\(noun) Settings" }
    var hasEpisodes: Bool { self != .movie }
    var symbol: String {
        switch self {
        case .movie: "film"
        case .show: "tv"
        case .anime: "sparkles.tv"
        }
    }
    /// "every episode of this show" / "this movie".
    var scopePhrase: String {
        switch self {
        case .movie: "this movie"
        case .show: "every episode of this show"
        case .anime: "every episode of this anime"
        }
    }
}

/// Settings the viewer chose for one movie, show or anime. Keyed by
/// `MediaItem.id` (`movie:<id>`, `tv:<id>`, `tv:kai:<slug>`), the same keys
/// as the older per-show intro times. Every option has its own switch; an
/// option that is off leaves the app's normal behaviour in charge.
struct TitleSettings: Codable, Hashable, Sendable {
    var title: String
    var kind: TitleKind
    /// The setup walkthrough ran (finished or dismissed) for this title.
    var setupCompleted = false
    var caption = CaptionDefault()
    var captionTiming = CaptionTiming()
    var audio: AudioDefault
    var skipping = SkipSettings()
    var nextEpisode = NextEpisodeTiming()
    var updatedAt = Date()

    init(title: String, kind: TitleKind) {
        self.title = title
        self.kind = kind
        self.audio = AudioDefault(choice: kind == .anime ? .animeTrack("Sub") : .language(code: "en", label: nil))
    }

    /// Anything switched on.
    var isCustomised: Bool {
        caption.enabled || captionTiming.enabled || audio.enabled || skipping.enabled || nextEpisode.enabled
    }

    /// The parts of these settings the player needs, for an episode of
    /// `season` (nil for movies, anime, or when it isn't known).
    func playback(season: Int?) -> TitlePlaybackConfig {
        let available = skipping.activeSegments(season: season).filter(\.isEnabled)
        var triggerSegments: [RecordedSegment] = []
        if nextEpisode.enabled, case .segment(let name) = nextEpisode.trigger {
            triggerSegments = available.filter { $0.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame }
        }
        return TitlePlaybackConfig(
            captionDefault: caption.enabled ? caption.choice : nil,
            captionConfidence: caption.minimumConfidence,
            nextEpisode: nextEpisode.enabled ? nextEpisode : nil,
            captionOffset: captionTiming.enabled ? captionTiming.offset : 0,
            audioDefault: audio.enabled ? audio.choice : nil,
            skipSource: skipping.enabled ? skipping.source : .online,
            recordedSegments: skipping.enabled && skipping.source == .recorded ? available : [],
            nextEpisodeSegments: triggerSegments
        )
    }

    var playback: TitlePlaybackConfig { playback(season: nil) }

    private enum CodingKeys: String, CodingKey {
        case title, kind, setupCompleted, caption, captionTiming, audio, skipping, nextEpisode, updatedAt
    }

    // Decoded field by field so settings saved by older builds (or a backup
    // from a newer one) still load, with defaults for anything missing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        kind = try c.decodeIfPresent(TitleKind.self, forKey: .kind) ?? .show
        setupCompleted = try c.decodeIfPresent(Bool.self, forKey: .setupCompleted) ?? false
        caption = (try? c.decodeIfPresent(CaptionDefault.self, forKey: .caption)) ?? CaptionDefault()
        captionTiming = (try? c.decodeIfPresent(CaptionTiming.self, forKey: .captionTiming)) ?? CaptionTiming()
        audio = (try? c.decodeIfPresent(AudioDefault.self, forKey: .audio))
            ?? AudioDefault(choice: kind == .anime ? .animeTrack("Sub") : .language(code: "en", label: nil))
        skipping = (try? c.decodeIfPresent(SkipSettings.self, forKey: .skipping)) ?? SkipSettings()
        nextEpisode = (try? c.decodeIfPresent(NextEpisodeTiming.self, forKey: .nextEpisode)) ?? NextEpisodeTiming()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

// MARK: - Captions

struct CaptionDefault: Codable, Hashable, Sendable {
    var enabled = false
    var choice: CaptionChoice = .language(code: "en", label: nil)
    /// The weakest track match accepted, 0...1 (see `CaptionMatcher`). At
    /// the default, any track in the right language that isn't a forced or
    /// signs-only track is fine.
    var minimumConfidence: Double = 0.5

    private enum CodingKeys: String, CodingKey { case enabled, choice, minimumConfidence }

    init(enabled: Bool = false, choice: CaptionChoice = .language(code: "en", label: nil), minimumConfidence: Double = 0.5) {
        self.enabled = enabled
        self.choice = choice
        self.minimumConfidence = minimumConfidence
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        choice = (try? c.decodeIfPresent(CaptionChoice.self, forKey: .choice)) ?? .language(code: "en", label: nil)
        minimumConfidence = min(1, max(0, try c.decodeIfPresent(Double.self, forKey: .minimumConfidence) ?? 0.5))
    }
}

/// When the player's Next Episode button appears, for shows and anime, and
/// whether the next episode starts by itself.
struct NextEpisodeTiming: Codable, Hashable, Sendable {
    enum Trigger: Codable, Hashable, Sendable {
        /// `secondsBeforeEnd` before the end.
        case beforeEnd
        /// When the credits found online start.
        case onlineCredits
        /// When one of the viewer's segments (by name) starts.
        case segment(name: String)
    }

    var enabled = false
    var trigger: Trigger = .beforeEnd
    /// Seconds before the end; also used when the trigger isn't found.
    var secondsBeforeEnd: Double = NextEpisodeTiming.appDefault
    /// Count down and play the next episode once the button appears.
    var autoPlay = false
    var countdown = 5

    static let appDefault: Double = 300
    static let range: ClosedRange<Double> = 10...1_200
    static let countdownRange: ClosedRange<Int> = 3...15

    init() {}

    private enum CodingKeys: String, CodingKey { case enabled, trigger, secondsBeforeEnd, autoPlay, countdown, atOutro }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        secondsBeforeEnd = try c.decodeIfPresent(Double.self, forKey: .secondsBeforeEnd) ?? Self.appDefault
        autoPlay = try c.decodeIfPresent(Bool.self, forKey: .autoPlay) ?? false
        countdown = min(Self.countdownRange.upperBound, max(Self.countdownRange.lowerBound,
                                                            try c.decodeIfPresent(Int.self, forKey: .countdown) ?? 5))
        if let trigger = try? c.decodeIfPresent(Trigger.self, forKey: .trigger) {
            self.trigger = trigger
        } else {
            // Older builds: a plain "when the credits start" switch.
            trigger = (try c.decodeIfPresent(Bool.self, forKey: .atOutro) ?? false) ? .onlineCredits : .beforeEnd
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(trigger, forKey: .trigger)
        try c.encode(secondsBeforeEnd, forKey: .secondsBeforeEnd)
        try c.encode(autoPlay, forKey: .autoPlay)
        try c.encode(countdown, forKey: .countdown)
    }
}

/// A caption choice that survives between episodes. Track names differ from
/// episode to episode, so a language is the main key; the exact track name
/// it was picked from is preferred when an episode has it.
enum CaptionChoice: Codable, Hashable, Sendable {
    case off
    case language(code: String, label: String?)
    /// On-device generated captions: "en-US", "ja-JP", or "ja-JP->en".
    case generated(locale: String)

    var title: String {
        switch self {
        case .off: return "Off"
        case .language(let code, let label):
            if code == "und" { return label ?? "Unknown Language" }
            let name = MediaLanguage.name(for: code)
            if let label, !label.isEmpty, label.caseInsensitiveCompare(name) != .orderedSame {
                return "\(name) (\(label))"
            }
            return name
        case .generated(let locale):
            switch locale {
            case "ja-JP": return "Japanese (Auto-generated)"
            case "ja-JP->en": return "Japanese → English (Auto-generated)"
            default: return "English (Auto-generated)"
            }
        }
    }
}

/// Moves captions relative to the picture. Positive shows them later.
struct CaptionTiming: Codable, Hashable, Sendable {
    var enabled = false
    var offset: Double = 0

    static let range: ClosedRange<Double> = -30...30

    static func describe(_ offset: Double) -> String {
        let value = abs(offset)
        if value < 0.05 { return "In sync" }
        let amount = value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f s", value) : String(format: "%.1f s", value)
        return offset > 0 ? "\(amount) later" : "\(amount) earlier"
    }
}

// MARK: - Audio

struct AudioDefault: Codable, Hashable, Sendable {
    var enabled = false
    var choice: AudioChoice
}

enum AudioChoice: Codable, Hashable, Sendable {
    /// Anime sources: "Sub" or "Dub".
    case animeTrack(String)
    /// An HLS audio track, by language (and the name it was picked from).
    case language(code: String, label: String?)

    var title: String {
        switch self {
        case .animeTrack(let track): return track == "Dub" ? "Dubbed" : "Subtitled (Japanese audio)"
        case .language(let code, let label):
            if code == "und" { return label ?? "Unknown Language" }
            let name = MediaLanguage.name(for: code)
            if let label, !label.isEmpty, label.caseInsensitiveCompare(name) != .orderedSame {
                return "\(name) (\(label))"
            }
            return name
        }
    }
}

// MARK: - Skipping

enum SkipSource: String, Codable, Hashable, Sendable {
    /// SkipDB, TheIntroDB, AniSkip and stream timestamps.
    case online
    /// Segments the viewer recorded, found in each episode as it plays.
    case recorded
}

/// Whether a show's segments apply to every season or each season has its
/// own (seasons often get a new opening).
enum SegmentScope: String, Codable, Hashable, Sendable {
    case show, season
}

struct SkipSettings: Codable, Hashable, Sendable {
    var enabled = false
    var source: SkipSource = .online
    var scope: SegmentScope = .show
    /// Segments for the whole title.
    var segments: [RecordedSegment] = []
    /// Per-season segments, keyed by season number ("1", "2", …).
    var seasonSegments: [String: [RecordedSegment]] = [:]
    /// Possible segments found in seasons that don't have them yet.
    var suggestions: [String: [SegmentSuggestion]] = [:]

    private enum CodingKeys: String, CodingKey { case enabled, source, scope, segments, seasonSegments, suggestions }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        source = (try? c.decodeIfPresent(SkipSource.self, forKey: .source)) ?? .online
        scope = (try? c.decodeIfPresent(SegmentScope.self, forKey: .scope)) ?? .show
        segments = (try? c.decodeIfPresent([RecordedSegment].self, forKey: .segments)) ?? []
        seasonSegments = (try? c.decodeIfPresent([String: [RecordedSegment]].self, forKey: .seasonSegments)) ?? [:]
        suggestions = (try? c.decodeIfPresent([String: [SegmentSuggestion]].self, forKey: .suggestions)) ?? [:]
    }

    /// Segments that apply to an episode of `season`.
    func activeSegments(season: Int?) -> [RecordedSegment] {
        guard scope == .season, let season else { return scope == .season ? [] : segments }
        return seasonSegments[String(season)] ?? []
    }

    func segments(season: Int) -> [RecordedSegment] { seasonSegments[String(season)] ?? [] }
    func suggestions(season: Int) -> [SegmentSuggestion] { suggestions[String(season)] ?? [] }

    /// Every recorded segment, whole-title and per season.
    var allSegments: [RecordedSegment] { segments + seasonSegments.values.flatMap { $0 } }

    func segment(_ id: UUID) -> RecordedSegment? { allSegments.first { $0.id == id } }

    /// The season a segment belongs to (nil: whole title).
    func season(of id: UUID) -> Int? {
        seasonSegments.first { $0.value.contains { $0.id == id } }.flatMap { Int($0.key) }
    }

    mutating func update(_ id: UUID, _ change: (inout RecordedSegment) -> Void) {
        if let index = segments.firstIndex(where: { $0.id == id }) {
            change(&segments[index])
            return
        }
        for key in seasonSegments.keys {
            if let index = seasonSegments[key]?.firstIndex(where: { $0.id == id }) {
                change(&seasonSegments[key]![index])
                return
            }
        }
    }

    mutating func remove(_ id: UUID) {
        segments.removeAll { $0.id == id }
        for key in seasonSegments.keys { seasonSegments[key]?.removeAll { $0.id == id } }
    }

    /// Adds or replaces a segment, in `season` or the whole title.
    mutating func put(_ segment: RecordedSegment, season: Int?) {
        // Replacing in place keeps the list's order.
        if let season, let index = seasonSegments[String(season)]?.firstIndex(where: { $0.id == segment.id }) {
            seasonSegments[String(season)]![index] = segment
            return
        }
        if season == nil, let index = segments.firstIndex(where: { $0.id == segment.id }) {
            segments[index] = segment
            return
        }
        remove(segment.id)
        if let season {
            seasonSegments[String(season), default: []].append(segment)
            // A real segment replaces suggestions of the same name.
            let name = segment.name.lowercased()
            suggestions[String(season)]?.removeAll { $0.name.lowercased() == name }
        } else {
            segments.append(segment)
        }
    }

    /// Takes remembered matches from a newer copy, so an edit made on an
    /// older copy doesn't lose them.
    mutating func adoptMatches(from newer: SkipSettings) {
        for segment in newer.allSegments {
            update(segment.id) { $0.matches = segment.matches }
        }
    }

    /// Distinct segment names, for choosing a Next Episode trigger.
    var segmentNames: [String] {
        var seen = Set<String>()
        return allSegments.map { $0.name.trimmingCharacters(in: .whitespaces) }
            .filter { seen.insert($0.lowercased()).inserted }
    }
}

/// A segment Vela thinks it found in a season that doesn't have one with
/// that name yet. Not used until the viewer checks and saves it.
struct SegmentSuggestion: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    /// The segment it was found from (in another season).
    var sourceID: UUID
    var name: String
    var episodeKey: String
    var episodeLabel: String
    var start: Double
    var duration: Double
    var detection: DetectionMethod
    var matchConfidence: Double
    var foundAt = Date()

    var buttonTitle: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Skip" : "Skip \(trimmed)"
    }
}

/// How a recorded segment is recognised in other episodes.
enum DetectionMethod: String, Codable, CaseIterable, Hashable, Sendable {
    case visual, audio, both

    var title: String {
        switch self {
        case .visual: "Picture"
        case .audio: "Sound"
        case .both: "Picture and Sound"
        }
    }

    var detail: String {
        switch self {
        case .visual: "Matches the frames. Works with every audio language."
        case .audio: "Matches the soundtrack. Good for intros over changing footage."
        case .both: "Whichever recognises it first."
        }
    }

    var usesVisual: Bool { self != .audio }
    var usesAudio: Bool { self != .visual }
}

/// A part of a show the viewer marked in one episode ("Skip Opening").
/// Its picture and sound fingerprints live in a file in Vela's own storage
/// (`SegmentLibrary`); this record only describes it.
struct RecordedSegment: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    /// Shown as "Skip <name>". May be empty, which shows just "Skip".
    var name: String
    var isEnabled = true
    var autoSkip = false
    var detection: DetectionMethod
    /// How sure Vela must be before it calls a match, 0...1.
    var matchConfidence: Double = 0.5
    /// Length of the segment, seconds.
    var duration: Double
    /// Where it was recorded, e.g. "S1 · E3".
    var sourceLabel: String
    var sourceKey: String
    var sourceStart: Double
    /// Which fingerprints the recording produced.
    var hasVisual: Bool
    var hasAudio: Bool
    var createdAt: Date
    /// Where it was found in each episode (progress key), so the next visit
    /// knows straight away.
    var matches: [String: SegmentMatch] = [:]

    var buttonTitle: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Skip" : "Skip \(trimmed)"
    }

    /// The detection actually usable with what was recorded.
    var effectiveDetection: DetectionMethod? {
        switch detection {
        case .visual: return hasVisual ? .visual : (hasAudio ? .audio : nil)
        case .audio: return hasAudio ? .audio : (hasVisual ? .visual : nil)
        case .both:
            if hasVisual && hasAudio { return .both }
            return hasVisual ? .visual : (hasAudio ? .audio : nil)
        }
    }

    /// A remembered position, if it was found in a video of the same length.
    func match(for episodeKey: String, videoDuration: Double) -> SegmentMatch? {
        guard let match = matches[episodeKey] else { return nil }
        guard videoDuration > 0, match.videoDuration > 0 else { return match }
        return abs(match.videoDuration - videoDuration) <= 3 ? match : nil
    }

    /// Enough for a long anime; keeps backups well under the cloud limit.
    static let maxRememberedMatches = 150

    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, autoSkip, detection, matchConfidence, duration, sourceLabel, sourceKey, sourceStart,
             hasVisual, hasAudio, createdAt, matches
    }

    init(id: UUID = UUID(), name: String, detection: DetectionMethod, duration: Double,
         sourceLabel: String, sourceKey: String, sourceStart: Double,
         hasVisual: Bool, hasAudio: Bool, autoSkip: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.detection = detection
        self.duration = duration
        self.sourceLabel = sourceLabel
        self.sourceKey = sourceKey
        self.sourceStart = sourceStart
        self.hasVisual = hasVisual
        self.hasAudio = hasAudio
        self.autoSkip = autoSkip
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        autoSkip = try c.decodeIfPresent(Bool.self, forKey: .autoSkip) ?? false
        detection = (try? c.decodeIfPresent(DetectionMethod.self, forKey: .detection)) ?? .visual
        matchConfidence = min(1, max(0, try c.decodeIfPresent(Double.self, forKey: .matchConfidence) ?? 0.5))
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        sourceLabel = try c.decodeIfPresent(String.self, forKey: .sourceLabel) ?? ""
        sourceKey = try c.decodeIfPresent(String.self, forKey: .sourceKey) ?? ""
        sourceStart = try c.decodeIfPresent(Double.self, forKey: .sourceStart) ?? 0
        hasVisual = try c.decodeIfPresent(Bool.self, forKey: .hasVisual) ?? false
        hasAudio = try c.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        matches = (try? c.decodeIfPresent([String: SegmentMatch].self, forKey: .matches)) ?? [:]
    }
}

struct SegmentMatch: Codable, Hashable, Sendable {
    /// Start of the segment in that episode, seconds.
    var start: Double
    /// Length of the video it was found in, to tell different cuts apart.
    var videoDuration: Double
    var foundAt: Date
}

/// What the player applies for the title that's playing.
struct TitlePlaybackConfig: Equatable, Sendable {
    var captionDefault: CaptionChoice?
    var captionConfidence: Double = 0.5
    var nextEpisode: NextEpisodeTiming?
    var captionOffset: Double
    var audioDefault: AudioChoice?
    var skipSource: SkipSource
    var recordedSegments: [RecordedSegment]
    /// Segments whose start shows the Next Episode button; looked for even
    /// when skipping doesn't use them.
    var nextEpisodeSegments: [RecordedSegment] = []

    /// Every segment the detector should look for.
    var detectionTargets: [RecordedSegment] {
        recordedSegments + nextEpisodeSegments.filter { segment in !recordedSegments.contains { $0.id == segment.id } }
    }

    /// Changes that need the segment detector restarted. Remembered matches
    /// are left out: saving one must not restart the search that found it.
    var skipSignature: [String] {
        [skipSource.rawValue] + nextEpisodeSegments.map { "next|\($0.id)" } + recordedSegments.map {
            "\($0.id)|\($0.name)|\($0.autoSkip)|\($0.detection.rawValue)|\($0.matchConfidence)|\($0.duration)|\($0.hasVisual)|\($0.hasAudio)"
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.captionDefault == rhs.captionDefault && lhs.captionConfidence == rhs.captionConfidence &&
            lhs.nextEpisode == rhs.nextEpisode && lhs.captionOffset == rhs.captionOffset &&
            lhs.audioDefault == rhs.audioDefault && lhs.skipSignature == rhs.skipSignature
    }
}
