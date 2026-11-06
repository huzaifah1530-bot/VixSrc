import Foundation

/// SkipDB-first timestamp lookups: TheIntroDB for TMDB TV and AniSkip
/// (through a verified MAL id) for anime fill missing types. Every call returns
/// `[]` on any failure, so missing data never affects playback. Mirrors
/// desktop/src/main/skip.ts.
actor IntroSkipService {
    static let shared = IntroSkipService()

    private struct Entry<T: Sendable>: Sendable { let at: Date; let ttl: TimeInterval; let value: T }
    private var segmentCache: [String: Entry<[SkipSegment]>] = [:]
    private var malCache: [String: Entry<MalMatch?>] = [:]
    private var skipDbAnimeIdCache: [String: Entry<String?>] = [:]

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

    // MARK: SkipDB → existing provider

    private func skipDB(imdbID: String?, season: Int?, episode: Int?, duration: Double) async -> [SkipSegment] {
        guard let imdbID, imdbID.range(of: #"^tt\d+$"#, options: .regularExpression) != nil else { return [] }
        let key = "skipdb:raw:\(imdbID):\(season ?? -1):\(episode ?? -1):\(Self.bucket(duration))"
        if let hit = fresh(segmentCache[key]) { return hit }
        var components = URLComponents(string: "https://api.skipdb.tv/api/segments")!
        var query = [URLQueryItem(name: "imdb_id", value: imdbID)]
        if let season, let episode {
            query += [URLQueryItem(name: "season", value: String(season)), URLQueryItem(name: "episode", value: String(episode))]
        }
        if duration > 0 { query.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        components.queryItems = query
        guard let url = components.url, let response = await getJSON(url), response.0 == 200 else { return [] }
        let json = response.1
        let segments = SkipSegments.valid(SkipSegments.fromSkipDB(json), duration: duration)
        segmentCache[key] = Entry(at: Date(), ttl: segments.isEmpty ? Self.missTTL : Self.hitTTL, value: segments)
        return segments
    }

    private func skipDBAnimeID(identity: AnimeIdentity) async -> String? {
        guard let title = identity.titles.first, let year = identity.aired.map({ String($0.prefix(4)) }) else { return nil }
        let key = "skipdb:anime-id:\(identity.cacheKey)"
        if let entry = skipDbAnimeIdCache[key], Date().timeIntervalSince(entry.at) < entry.ttl { return entry.value }
        var components = URLComponents(string: "https://skipdb.tv/api/titles/search")!
        components.queryItems = [URLQueryItem(name: "q", value: title)]
        guard let url = components.url, let response = await getJSON(url), response.0 == 200 else { return nil }
        let local = response.1["local"] as? [[String: Any]] ?? []
        let names = Set(identity.titles.map(AnimeIdentity.normTitle))
        let ids = Set(local.compactMap { row -> String? in
            guard let id = row["imdb_id"] as? String,
                  id.range(of: #"^tt\d+$"#, options: .regularExpression) != nil,
                  String(describing: row["year"] ?? "") == year,
                  row["mediaType"] as? String == (identity.type == "movie" ? "movie" : "series"),
                  let name = row["name"] as? String,
                  names.contains(AnimeIdentity.normTitle(name)) else { return nil }
            return id
        })
        let value = ids.count == 1 ? ids.first : nil
        skipDbAnimeIdCache[key] = Entry(at: Date(), ttl: value == nil ? Self.missTTL : Self.hitTTL, value: value)
        return value
    }

    func movie(tmdbId: String, duration: Double, credential: String) async -> [SkipSegment] {
        let key = "skipdb:movie:\(tmdbId):\(Self.bucket(duration))"
        if let hit = fresh(segmentCache[key]) { return hit }
        let imdb = await TMDBClient().imdbID(type: .movie, tmdbId: tmdbId, credential: credential)
        let segments = await skipDB(imdbID: imdb, season: nil, episode: nil, duration: duration)
        segmentCache[key] = Entry(at: Date(), ttl: segments.isEmpty ? Self.missTTL : Self.hitTTL, value: segments)
        return segments
    }

    // MARK: TheIntroDB fallback

    /// v4 resolves `tmdb_id` server-side and reads season/episode in TMDB's
    /// numbering for it (verified with One Piece: TMDB S22E1100 = TVDB
    /// S22E15), so TMDB numbers are sent as-is, never guessed into TVDB order.
    func tv(tmdbId: String, season: Int, episode: Int, duration: Double, credential: String) async -> [SkipSegment] {
        guard !tmdbId.isEmpty, tmdbId.allSatisfy(\.isASCII), Int(tmdbId) != nil, season >= 0, episode >= 0 else { return [] }
        let d = Self.bucket(duration)
        let key = "skipdb:tv:\(tmdbId):\(season):\(episode):\(d)"
        if let hit = fresh(segmentCache[key]) { return hit }
        let imdb = await TMDBClient().imdbID(type: .tv, tmdbId: tmdbId, credential: credential)
        let primary = await skipDB(imdbID: imdb, season: season, episode: episode, duration: duration)
        if primary.contains(where: { $0.kind == .intro }) && primary.contains(where: { $0.kind == .outro }) {
            segmentCache[key] = Entry(at: Date(), ttl: Self.hitTTL, value: primary)
            return primary
        }
        var components = URLComponents(string: "https://api.theintrodb.org/v4/media")!
        var items = [
            URLQueryItem(name: "tmdb_id", value: tmdbId),
            URLQueryItem(name: "season", value: String(season)),
            URLQueryItem(name: "episode", value: String(episode))
        ]
        if d >= 300 { items.append(URLQueryItem(name: "duration_ms", value: String(Int((duration * 1000).rounded())))) }
        components.queryItems = items
        guard let url = components.url, let response = await getJSON(url) else { return primary }
        let (status, json) = response
        if status == 404 {
            segmentCache[key] = Entry(at: Date(), ttl: primary.isEmpty ? Self.missTTL : Self.hitTTL, value: primary)
            return primary
        }
        guard status == 200 else { return primary } // errors aren't cached
        // Must be the episode we asked for.
        guard json["type"] as? String == "tv",
              (json["season"] as? NSNumber)?.intValue == season,
              (json["episode"] as? NSNumber)?.intValue == episode else {
            return primary
        }
        let segments = SkipSegments.merge(duration: duration, sources: [primary, SkipSegments.fromTheIntroDB(json)])
        segmentCache[key] = Entry(at: Date(), ttl: segments.isEmpty ? Self.missTTL : Self.hitTTL, value: segments)
        return segments
    }

    // MARK: AniSkip

    func anime(identity: AnimeIdentity, episode: String, duration: Double, credential: String) async -> [SkipSegment] {
        let number = Int(episode)
        let imdb: String?
        if let local = await skipDBAnimeID(identity: identity) {
            imdb = local
        } else {
            imdb = await TMDBClient().animeIMDbID(identity: identity, credential: credential)
        }
        let primary: [SkipSegment]
        if identity.type == "movie" {
            primary = await skipDB(imdbID: imdb, season: nil, episode: nil, duration: duration)
        } else if let number, number > 0 {
            primary = await skipDB(imdbID: imdb, season: 1, episode: number, duration: duration)
        } else {
            primary = []
        }
        if primary.contains(where: { $0.kind == .intro }) && primary.contains(where: { $0.kind == .outro }) { return primary }
        guard let match = await malMatch(for: identity),
              let ep = AnimeMatching.aniSkipEpisode(episode, identity: identity, candidate: match.candidate) else { return primary }
        let length = duration > 0 ? Int(duration.rounded()) : 0
        let key = "skipdb:anime:\(match.malId):\(ep):\(Self.bucket(Double(length)))"
        if let hit = fresh(segmentCache[key]) { return hit }
        // `episodeLength` lets AniSkip pick timestamps submitted for this cut.
        guard let url = URL(string: "https://api.aniskip.com/v2/skip-times/\(match.malId)/\(ep)?types[]=op&types[]=ed&episodeLength=\(length)"),
              let response = await getJSON(url) else { return primary }
        let (status, json) = response
        if status == 404 {
            segmentCache[key] = Entry(at: Date(), ttl: primary.isEmpty ? Self.missTTL : Self.hitTTL, value: primary)
            return primary
        }
        guard status == 200 else { return primary }
        let segments = SkipSegments.merge(duration: duration, sources: [primary, SkipSegments.fromAniSkip(json)])
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
