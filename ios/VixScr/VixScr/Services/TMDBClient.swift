import Foundation

enum TMDBError: LocalizedError {
    case missingCredential
    case http(Int, String)
    case decoding

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            return "Missing TMDB API key or read access token."
        case let .http(code, detail):
            return "TMDB \(code)\(detail.isEmpty ? "" : " — \(detail)")"
        case .decoding:
            return "Could not read the TMDB response."
        }
    }
}

/// Talks to the public TMDB v3 API. Mirrors `tmdbFetch()` in index.html,
/// including the v3 api_key vs v4 bearer token detection.
actor TMDBClient {
    private let base = URL(string: "https://api.themoviedb.org/3")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private func isBearerToken(_ credential: String) -> Bool {
        credential.hasPrefix("eyJ") || credential.count > 60
    }

    private func request(_ path: String, credential: String, query: [String: String] = [:]) async throws -> Data {
        let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TMDBError.missingCredential }

        // Callers pass paths with a leading slash ("/tv/123"), and `base`
        // already ends in "/3", so appendingPathComponent would produce
        // ".../3//tv/123". Trim to match `TMDB_BASE + path` in index.html.
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var components = URLComponents(
            url: base.appendingPathComponent(normalizedPath),
            resolvingAgainstBaseURL: false
        ) else {
            throw TMDBError.decoding
        }

        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        if !query.keys.contains("language") {
            items.append(URLQueryItem(name: "language", value: "en-GB"))
        }

        if isBearerToken(trimmed) == false {
            items.append(URLQueryItem(name: "api_key", value: trimmed))
        }
        components.queryItems = items

        guard let url = components.url else { throw TMDBError.decoding }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if isBearerToken(trimmed) {
            request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TMDBError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(TMDBErrorResponse.self, from: data))?.statusMessage ?? ""
            throw TMDBError.http(http.statusCode, detail)
        }
        return data
    }

    func list(_ path: String, credential: String, query: [String: String] = [:]) async throws -> [TMDBRawItem] {
        let data = try await request(path, credential: credential, query: query)
        return (try? JSONDecoder().decode(TMDBListResponse.self, from: data))?.results ?? []
    }

    func tvDetails(id: String, credential: String) async throws -> TVDetails {
        let data = try await request("/tv/\(id)", credential: credential)
        guard let decoded = try? JSONDecoder().decode(TVDetails.self, from: data) else { throw TMDBError.decoding }
        return decoded
    }

    func season(tvId: String, seasonNumber: Int, credential: String) async throws -> SeasonDetails {
        let data = try await request("/tv/\(tvId)/season/\(seasonNumber)", credential: credential)
        guard let decoded = try? JSONDecoder().decode(SeasonDetails.self, from: data) else { throw TMDBError.decoding }
        return decoded
    }

    func credits(type: MediaItem.MediaType, tmdbId: String, credential: String) async throws -> CreditsResponse {
        let data = try await request("/\(type.rawValue)/\(tmdbId)/credits", credential: credential)
        guard let decoded = try? JSONDecoder().decode(CreditsResponse.self, from: data) else { throw TMDBError.decoding }
        return decoded
    }

    func imdbID(type: MediaItem.MediaType, tmdbId: String, credential: String) async -> String? {
        guard let data = try? await request("/\(type.rawValue)/\(tmdbId)/external_ids", credential: credential),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["imdb_id"] as? String, id.range(of: #"^tt\d+$"#, options: .regularExpression) != nil else { return nil }
        return id
    }

    /// Anime sites use their own IDs. Match a TMDB series only on title and full air date.
    func animeIMDbID(identity: AnimeIdentity, credential: String) async -> String? {
        guard let aired = identity.aired, let title = identity.titles.first else { return nil }
        let media = identity.type == "movie" ? "movie" : "tv"
        let query = ["query": title]
        guard let data = try? await request("/search/\(media)", credential: credential, query: query),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }
        let names = Set(identity.titles.map(AnimeIdentity.normTitle))
        let matches = results.filter { row in
            guard (row["first_air_date"] ?? row["release_date"]) as? String == aired else { return false }
            return [row["name"] as? String, row["original_name"] as? String,
                    row["title"] as? String, row["original_title"] as? String]
                .compactMap { $0 }.contains { names.contains(AnimeIdentity.normTitle($0)) }
        }
        guard matches.count == 1, let id = matches[0]["id"] as? NSNumber else { return nil }
        return await imdbID(type: identity.type == "movie" ? .movie : .tv,
                            tmdbId: id.stringValue, credential: credential)
    }

    /// Fetches `/movie/{id}` or `/tv/{id}` directly, used for deep links
    /// where the media type isn't known yet (mirrors `openContentByTmdbId`,
    /// which tries movie first then falls back to tv).
    func detail(type: MediaItem.MediaType, tmdbId: String, credential: String) async throws -> MediaItem? {
        let data = try await request("/\(type.rawValue)/\(tmdbId)", credential: credential)
        guard let decoded = try? JSONDecoder().decode(TMDBDetailResponse.self, from: data) else { throw TMDBError.decoding }
        return decoded.normalized(type: type)
    }
}
