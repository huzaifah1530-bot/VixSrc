import Foundation

/// A skippable part of an episode, in seconds. Mirrors `SkipSegment` and
/// the helpers in desktop/src/shared/introSkip.ts; keep the two in step
/// (desktop's `npm run test:intro` covers the shared rules).
struct SkipSegment: Hashable, Sendable {
    enum Kind: String, Sendable { case intro, outro }
    enum Source: String, Sendable { case stream, theintrodb, aniskip, custom }

    /// Only intros are skipped today; outros (credits / ED) are kept for later.
    let kind: Kind
    let start: Double
    let end: Double
    let source: Source
}

/// Intro times the user set for a whole show; replaces found intros.
/// Keyed like desktop: `tv:<tmdbId>` or `tv:kai:<slug>`.
struct IntroOverride: Codable, Hashable, Sendable {
    var title: String
    var start: Double?
    var end: Double?

    var isComplete: Bool {
        guard let start, let end else { return false }
        return end > start
    }
}

enum SkipSegments {
    /// A complete custom intro replaces every found intro; outros stay.
    static func withOverride(_ found: [SkipSegment], _ override: IntroOverride?) -> [SkipSegment] {
        guard let override, override.isComplete, let start = override.start, let end = override.end else { return found }
        return [SkipSegment(kind: .intro, start: start, end: end, source: .custom)] + found.filter { $0.kind != .intro }
    }

    /// Longest plausible intro; anything longer is treated as bad data.
    static let maxIntroSeconds: Double = 600
    static let minSegmentSeconds: Double = 3

    /// Keeps a segment only if it makes sense for this video (`duration` 0 = unknown).
    static func valid(_ s: SkipSegment, duration: Double) -> SkipSegment? {
        guard s.start.isFinite, s.end.isFinite, s.start >= 0 else { return nil }
        var end = s.end
        if duration > 0 {
            if s.start >= duration - minSegmentSeconds { return nil }
            if end > duration + 2 { return nil }
            end = min(end, duration)
        }
        guard end - s.start >= minSegmentSeconds else { return nil }
        if s.kind == .intro && end - s.start > maxIntroSeconds { return nil }
        return SkipSegment(kind: s.kind, start: s.start, end: end, source: s.source)
    }

    static func valid(_ list: [SkipSegment], duration: Double) -> [SkipSegment] {
        var out: [SkipSegment] = []
        for s in list {
            guard let v = valid(s, duration: duration) else { continue }
            if !out.contains(where: { $0.kind == v.kind && abs($0.start - v.start) < 1 }) { out.append(v) }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// The intro the playhead is in (and not in its last second), if any.
    static func activeIntro(_ segments: [SkipSegment], at t: Double) -> SkipSegment? {
        segments.first { $0.kind == .intro && t >= $0.start && t < $0.end - 1 }
    }

    // MARK: Parsers

    /// MegaPlay / VidTube getSources: `intro: {start, end}` in seconds; 0/0 = none.
    static func fromStream(_ json: [String: Any]) -> [SkipSegment] {
        var out: [SkipSegment] = []
        for (key, kind) in [("intro", SkipSegment.Kind.intro), ("outro", SkipSegment.Kind.outro)] {
            guard let r = json[key] as? [String: Any],
                  let start = number(r["start"]), let end = number(r["end"]), end > start else { continue }
            out.append(SkipSegment(kind: kind, start: start, end: end, source: .stream))
        }
        return out
    }

    /// TheIntroDB v4 GET /media body (ms; null start = 0, null end = to the end).
    static func fromTheIntroDB(_ json: [String: Any]) -> [SkipSegment] {
        var out: [SkipSegment] = []
        for (field, kind) in [("intro", SkipSegment.Kind.intro), ("credits", SkipSegment.Kind.outro)] {
            for r in json[field] as? [[String: Any]] ?? [] {
                // An intro without a known end isn't skippable.
                guard let endMs = number(r["end_ms"]) else { continue }
                let startMs = number(r["start_ms"]) ?? 0
                out.append(SkipSegment(kind: kind, start: startMs / 1000, end: endMs / 1000, source: .theintrodb))
            }
        }
        return out
    }

    /// AniSkip v2 /skip-times: `op` → intro, `ed` → outro.
    static func fromAniSkip(_ json: [String: Any]) -> [SkipSegment] {
        guard json["found"] as? Bool == true, let results = json["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { r in
            let kind: SkipSegment.Kind? = (r["skipType"] as? String) == "op" ? .intro : (r["skipType"] as? String) == "ed" ? .outro : nil
            guard let kind, let interval = r["interval"] as? [String: Any],
                  let start = number(interval["startTime"]), let end = number(interval["endTime"]) else { return nil }
            return SkipSegment(kind: kind, start: start, end: end, source: .aniskip)
        }
    }

    private static func number(_ v: Any?) -> Double? {
        if v is NSNull { return nil }
        if let n = v as? NSNumber { let d = n.doubleValue; return d.isFinite ? d : nil }
        if let s = v as? String, let d = Double(s), d.isFinite { return d }
        return nil
    }
}

// MARK: - Anime identity (catalogue page → MAL id via Kitsu mappings)

/// What an AnimeKai / AniKoto watch page says about the show.
struct AnimeIdentity: Hashable, Sendable {
    /// Heading, data-jp and the `.names` synonyms.
    var titles: [String]
    /// Normalised: tv | movie | ova | ona | special | music
    var type: String
    /// First air date, YYYY-MM-DD.
    var aired: String?
    var episodes: Int?

    var cacheKey: String {
        ([type, aired ?? "", episodes.map(String.init) ?? ""] + titles.map(AnimeIdentity.normTitle).sorted()).joined(separator: "|")
    }

    static func normTitle(_ t: String) -> String {
        var s = t.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        if let r = s.range(of: #"\((tv|ona|ova)\)\s*$"#, options: .regularExpression) { s.removeSubrange(r) }
        s = s.replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func normType(_ t: String) -> String {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s == "tv special" { return "special" }
        return ["tv", "movie", "ova", "ona", "special", "music"].contains(s) ? s : ""
    }

    /// "Oct 3, 2020 to Mar 27, 2021" → "2020-10-03". Needs a full day.
    static func parseAired(_ text: String) -> String? {
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        guard let regex = try? NSRegularExpression(pattern: #"([A-Za-z]{3})[a-z]*\.?\s+(\d{1,2}),\s*(\d{4})"#),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let monR = Range(m.range(at: 1), in: text), let dayR = Range(m.range(at: 2), in: text),
              let yearR = Range(m.range(at: 3), in: text),
              let month = months.firstIndex(of: text[monR].lowercased()),
              let day = Int(text[dayR]) else { return nil }
        return String(format: "%@-%02d-%02d", String(text[yearR]), month + 1, day)
    }
}

struct KitsuCandidate: Hashable, Sendable {
    var malId: Int?
    var titles: [String]
    var subtype: String
    var startDate: String?
    var episodeCount: Int?
}

enum AnimeMatching {
    private static func day(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(s.prefix(10)))
    }

    /// Not a fuzzy match: exact normalised title, same type, same first air
    /// date (±1 day) and agreeing episode counts; exactly one MAL id or nil.
    static func malId(for identity: AnimeIdentity, in candidates: [KitsuCandidate]) -> Int? {
        let titles = Set(identity.titles.map(AnimeIdentity.normTitle).filter { !$0.isEmpty })
        guard !titles.isEmpty, !identity.type.isEmpty, let aired = identity.aired, let airedDay = day(aired) else { return nil }
        var ids = Set<Int>()
        for c in candidates {
            guard let mal = c.malId, let start = c.startDate, let startDay = day(start) else { continue }
            guard AnimeIdentity.normType(c.subtype) == identity.type else { continue }
            guard abs(startDay.timeIntervalSince(airedDay)) <= 86_400 else { continue }
            if let a = identity.episodes, let b = c.episodeCount, a != b { continue }
            guard c.titles.contains(where: { titles.contains(AnimeIdentity.normTitle($0)) }) else { continue }
            ids.insert(mal)
        }
        return ids.count == 1 ? ids.first : nil
    }

    /// The AniSkip episode number, or nil when it can't be trusted.
    static func aniSkipEpisode(_ episode: String, identity: AnimeIdentity, candidate: KitsuCandidate?) -> Int? {
        let trimmed = episode.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber), let n = Int(trimmed), n >= 1 else { return nil }
        if let total = candidate?.episodeCount ?? identity.episodes, n > total { return nil }
        return n
    }

    static func parseKitsu(_ json: [String: Any]) -> [KitsuCandidate] {
        var mal: [String: Int] = [:]
        for inc in json["included"] as? [[String: Any]] ?? [] {
            guard inc["type"] as? String == "mappings",
                  let attrs = inc["attributes"] as? [String: Any],
                  attrs["externalSite"] as? String == "myanimelist/anime",
                  let idString = attrs["externalId"] as? String, let id = Int(idString), id > 0 else { continue }
            mal["\(inc["id"] ?? "")"] = id
        }
        return (json["data"] as? [[String: Any]] ?? []).map { d in
            let a = d["attributes"] as? [String: Any] ?? [:]
            let rel = (d["relationships"] as? [String: Any])?["mappings"] as? [String: Any]
            let links = rel?["data"] as? [[String: Any]] ?? []
            let malIds = Set(links.compactMap { mal["\($0["id"] ?? "")"] })
            var titles: [String] = []
            if let c = a["canonicalTitle"] as? String { titles.append(c) }
            if let t = a["titles"] as? [String: Any] { titles += t.values.compactMap { $0 as? String } }
            titles += a["abbreviatedTitles"] as? [String] ?? []
            let count = (a["episodeCount"] as? NSNumber)?.intValue
            return KitsuCandidate(
                malId: malIds.count == 1 ? malIds.first : nil,
                titles: titles.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                subtype: a["subtype"] as? String ?? "",
                startDate: a["startDate"] as? String,
                episodeCount: (count ?? 0) > 0 ? count : nil
            )
        }
    }
}

// MARK: - Auto-skip

/// Each intro fires at most once per episode, and only when playback runs
/// into it (or begins inside it). Seeking or rewinding into an intro marks
/// it handled without jumping. Same rules as desktop's AutoSkipTracker.
struct AutoSkipTracker {
    private var last: Double?
    private var fresh = true
    var handled: Set<String> = []

    mutating func restart() { last = nil; fresh = true }

    /// Returns the time to seek to, or nil.
    mutating func step(episodeKey: String, segments: [SkipSegment], time t: Double, allowed: Bool) -> Double? {
        let prev = last
        let wasFresh = fresh
        last = t
        fresh = false
        guard let intro = SkipSegments.activeIntro(segments, at: t) else { return nil }
        let key = "\(episodeKey)|\(Int(intro.start.rounded()))"
        if handled.contains(key) { return nil }
        let natural = prev.map { t >= $0 && t - $0 <= 2 } ?? false
        let enteredByPlaying = natural && (prev ?? 0) < intro.start + 2
        let started = wasFresh || prev == nil
        if !enteredByPlaying && !started {
            if !natural { handled.insert(key) }
            return nil
        }
        handled.insert(key)
        return allowed ? intro.end : nil
    }
}
