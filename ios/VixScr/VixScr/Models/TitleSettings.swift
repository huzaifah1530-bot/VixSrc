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
    var updatedAt = Date()

    init(title: String, kind: TitleKind) {
        self.title = title
        self.kind = kind
        self.audio = AudioDefault(choice: kind == .anime ? .animeTrack("Sub") : .language(code: "en", label: nil))
    }

    /// Anything switched on.
    var isCustomised: Bool { caption.enabled || captionTiming.enabled || audio.enabled || skipping.enabled }

    /// The parts of these settings the player needs.
    var playback: TitlePlaybackConfig {
        TitlePlaybackConfig(
            captionDefault: caption.enabled ? caption.choice : nil,
            captionOffset: captionTiming.enabled ? captionTiming.offset : 0,
            audioDefault: audio.enabled ? audio.choice : nil,
            skipSource: skipping.enabled ? skipping.source : .online,
            recordedSegments: skipping.enabled && skipping.source == .recorded
                ? skipping.segments.filter(\.isEnabled) : []
        )
    }

    private enum CodingKeys: String, CodingKey {
        case title, kind, setupCompleted, caption, captionTiming, audio, skipping, updatedAt
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
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

// MARK: - Captions

struct CaptionDefault: Codable, Hashable, Sendable {
    var enabled = false
    var choice: CaptionChoice = .language(code: "en", label: nil)
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

struct SkipSettings: Codable, Hashable, Sendable {
    var enabled = false
    var source: SkipSource = .online
    var segments: [RecordedSegment] = []

    private enum CodingKeys: String, CodingKey { case enabled, source, segments }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        source = (try? c.decodeIfPresent(SkipSource.self, forKey: .source)) ?? .online
        segments = (try? c.decodeIfPresent([RecordedSegment].self, forKey: .segments)) ?? []
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
        case id, name, isEnabled, autoSkip, detection, duration, sourceLabel, sourceKey, sourceStart,
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
    var captionOffset: Double
    var audioDefault: AudioChoice?
    var skipSource: SkipSource
    var recordedSegments: [RecordedSegment]

    /// Changes that need the segment detector restarted. Remembered matches
    /// are left out: saving one must not restart the search that found it.
    var skipSignature: [String] {
        [skipSource.rawValue] + recordedSegments.map {
            "\($0.id)|\($0.name)|\($0.autoSkip)|\($0.detection.rawValue)|\($0.duration)|\($0.hasVisual)|\($0.hasAudio)"
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.captionDefault == rhs.captionDefault && lhs.captionOffset == rhs.captionOffset &&
            lhs.audioDefault == rhs.audioDefault && lhs.skipSignature == rhs.skipSignature
    }
}
