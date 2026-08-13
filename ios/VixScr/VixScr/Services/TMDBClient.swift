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

        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        if !query.keys.contains("language") {
            items.append(URLQueryItem(name: "language", value: "en-GB"))
        }

        var request = URLRequest(url: base)
        request.setValue("application/json", forHTTPHeaderField: "accept")

        if isBearerToken(trimmed) {
            request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        } else {
            items.append(URLQueryItem(name: "api_key", value: trimmed))
        }
        components.queryItems = items
        request.url = components.url

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

    /// Fetches `/movie/{id}` or `/tv/{id}` directly, used for deep links
    /// where the media type isn't known yet (mirrors `openContentByTmdbId`,
    /// which tries movie first then falls back to tv).
    func detail(type: MediaItem.MediaType, tmdbId: String, credential: String) async throws -> MediaItem? {
        let data = try await request("/\(type.rawValue)/\(tmdbId)", credential: credential)
        guard let decoded = try? JSONDecoder().decode(TMDBDetailResponse.self, from: data) else { throw TMDBError.decoding }
        return decoded.normalized(type: type)
    }
}
