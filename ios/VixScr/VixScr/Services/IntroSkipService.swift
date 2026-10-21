import Foundation

/// Intro timestamp lookups: TheIntroDB for TMDB TV episodes and AniSkip
/// (through a verified MAL id) for the anime catalogue. Every call returns
/// `[]` on any failure, so missing data never affects playback. Mirrors
/// desktop/src/main/skip.ts.
actor IntroSkipService {
    static let shared = IntroSkipService()

    private struct Entry<T: Sendable>: Sendable { let at: Date; let ttl: TimeInterval; let value: T }
    private var segmentCache: [String: Entry<[SkipSegment]>] = [:]
    private var malCache: [String: Entry<MalMatch?>] = [:]

    private struct MalMatch: Sendable { let malId: Int; let candidate: KitsuCandidate }

    private static let hitTTL: TimeInterval = 24 * 3600
    /// "No data" is a real answer too, but submissions arrive over time.
    private static let missTTL: TimeInterval = 30 * 60
    private static let userAgent = "Vela (+https://github.com/huzaifah1530-bot/Vela)"

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    /// Duration bucket: both APIs pick a release version by length.
    private static func bucket(_ d: Double) -> Int { d > 0 ? Int((d / 10).rounded()) * 10 : 0 }

    private func fresh<T: Sendable>(_ e: Entry<T>?) -> T? {
        guard let e, Date().timeIntervalSince(e.at) < e.ttl else { return nil }
        return e.value
    }

    /// (status, JSON object) or nil on a network error / non-JSON body.
    private func getJSON(_ url: URL, accept: String = "application/json") async -> (Int, [String: Any])? {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        guard let result = try? await session.data(for: request),
              let http = result.1 as? HTTPURLResponse else { return nil }
        let json = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any] ?? [:]
        return (http.statusCode, json)
    }

    // MARK: TheIntroDB

    /// v4 resolves `tmdb_id` server-side and reads season/episode in TMDB's
    /// numbering for it (verified with One Piece: TMDB S22E1100 = TVDB
    /// S22E15), so TMDB numbers are sent as-is, never guessed into TVDB order.
    func tv(tmdbId: String, season: Int, episode: Int, duration: Double) async -> [SkipSegment] {
        guard !tmdbId.isEmpty, tmdbId.allSatisfy(\.isASCII), Int(tmdbId) != nil, season >= 0, episode >= 0 else { return [] }
        let d = Self.bucket(duration)
        let key = "tidb:\(tmdbId):\(season):\(episode):\(d)"
        if let hit = fresh(segmentCache[key]) { return hit }
        var components = URLComponents(string: "https://api.theintrodb.org/v4/media")!
        var items = [
            URLQueryItem(name: "tmdb_id", value: tmdbId),
            URLQueryItem(name: "season", value: String(season)),
            URLQueryItem(name: "episode", value: String(episode))
        ]
        if d >= 300 { items.append(URLQueryItem(name: "duration_ms", value: String(Int((duration * 1000).rounded())))) }
        components.queryItems = items
        guard let url = components.url, let response = await getJSON(url) else { return [] }
        let (status, json) = response
        if status == 404 {
            segmentCache[key] = Entry(at: Date(), ttl: Self.missTTL, value: [])
            return []
        }
        guard status == 200 else { return [] } // errors aren't cached
        // Must be the episode we asked for.
        guard json["type"] as? String == "tv",
              (json["season"] as? NSNumber)?.intValue == season,
              (json["episode"] as? NSNumber)?.intValue == episode else {
            segmentCache[key] = Entry(at: Date(), ttl: Self.missTTL, value: [])
            return []
        }
        let segments = SkipSegments.fromTheIntroDB(json)
        segmentCache[key] = Entry(at: Date(), ttl: segments.isEmpty ? Self.missTTL : Self.hitTTL, value: segments)
        return segments
    }

    // MARK: AniSkip

    func anime(identity: AnimeIdentity, episode: String, duration: Double) async -> [SkipSegment] {
        guard let match = await malMatch(for: identity),
              let ep = AnimeMatching.aniSkipEpisode(episode, identity: identity, candidate: match.candidate) else { return [] }
        let length = duration > 0 ? Int(duration.rounded()) : 0
        let key = "aniskip:\(match.malId):\(ep):\(Self.bucket(Double(length)))"
        if let hit = fresh(segmentCache[key]) { return hit }
        // `episodeLength` lets AniSkip pick timestamps submitted for this cut.
        guard let url = URL(string: "https://api.aniskip.com/v2/skip-times/\(match.malId)/\(ep)?types[]=op&types[]=ed&episodeLength=\(length)"),
              let response = await getJSON(url) else { return [] }
        let (status, json) = response
        if status == 404 {
            segmentCache[key] = Entry(at: Date(), ttl: Self.missTTL, value: [])
            return []
        }
        guard status == 200 else { return [] }
        let segments = SkipSegments.fromAniSkip(json)
        segmentCache[key] = Entry(at: Date(), ttl: segments.isEmpty ? Self.missTTL : Self.hitTTL, value: segments)
        return segments
    }

    private func malMatch(for identity: AnimeIdentity) async -> MalMatch? {
        let key = identity.cacheKey
        if let e = malCache[key], Date().timeIntervalSince(e.at) < e.ttl { return e.value }
        var queries: [String] = []
        for t in identity.titles {
            let q = t.replacingOccurrences(of: #"\((tv|ona|ova)\)\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespaces)
            if !q.isEmpty && !queries.contains(q) { queries.append(q) }
        }
        var all: [KitsuCandidate] = []
        var answered = false
        for q in queries.prefix(3) {
            var c = URLComponents(string: "https://kitsu.io/api/edge/anime")!
            c.queryItems = [
                URLQueryItem(name: "filter[text]", value: q),
                URLQueryItem(name: "page[limit]", value: "20"),
                URLQueryItem(name: "include", value: "mappings"),
                URLQueryItem(name: "fields[anime]", value: "canonicalTitle,titles,abbreviatedTitles,subtype,startDate,episodeCount,mappings"),
                URLQueryItem(name: "fields[mappings]", value: "externalSite,externalId")
            ]
            guard let url = c.url, let response = await getJSON(url, accept: "application/vnd.api+json"),
                  response.0 == 200 else { continue }
            answered = true
            all += AnimeMatching.parseKitsu(response.1)
            if let id = AnimeMatching.malId(for: identity, in: all), let candidate = all.first(where: { $0.malId == id }) {
                let match = MalMatch(malId: id, candidate: candidate)
                malCache[key] = Entry(at: Date(), ttl: Self.hitTTL, value: match)
                return match
            }
        }
        if answered { malCache[key] = Entry(at: Date(), ttl: Self.missTTL, value: nil) }
        return nil
    }
}
