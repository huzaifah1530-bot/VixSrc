import Foundation

/// Full `/tv/{id}` response fields we actually use.
struct TVDetails: Codable {
    var id: Int
    var name: String
    var overview: String?
    var firstAirDate: String?
    var numberOfSeasons: Int?
    var numberOfEpisodes: Int?
    var voteAverage: Double?
    var seasons: [SeasonSummary]?
    var genres: [TMDBDetailResponse.Genre]?
    var originalLanguage: String?
    var originCountry: [String]?

    var isAnime: Bool {
        AnimeClassifier.isAnime(genreIds: genres?.map(\.id), originalLanguage: originalLanguage, originCountry: originCountry)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, overview, genres
        case originalLanguage = "original_language"
        case originCountry = "origin_country"
        case firstAirDate = "first_air_date"
        case numberOfSeasons = "number_of_seasons"
        case numberOfEpisodes = "number_of_episodes"
        case voteAverage = "vote_average"
        case seasons
    }

    /// Mirrors `getUsableSeasons()`: only seasons with a positive number and
    /// at least one episode are shown (this hides "Season 0" specials).
    var usableSeasons: [SeasonSummary] {
        (seasons ?? [])
            .filter { $0.seasonNumber > 0 && ($0.episodeCount ?? 0) > 0 }
            .sorted { $0.seasonNumber < $1.seasonNumber }
    }
}

struct SeasonSummary: Codable, Identifiable, Hashable {
    var id: Int
    var seasonNumber: Int
    var episodeCount: Int?
    var name: String?

    enum CodingKeys: String, CodingKey {
        case id
        case seasonNumber = "season_number"
        case episodeCount = "episode_count"
        case name
    }
}

/// Full `/tv/{id}/season/{n}` response.
struct SeasonDetails: Codable {
    var episodes: [Episode]?
}

struct Episode: Codable, Identifiable, Hashable {
    var id: Int
    var episodeNumber: Int
    var name: String?
    var overview: String?
    var stillPath: String?
    var runtime: Int?
    /// Injected after fetch so NextEpisodeButton can display "S2E1" labels.
    var seasonNumber: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case episodeNumber = "episode_number"
        case name, overview
        case stillPath = "still_path"
        case runtime
        // seasonNumber is not in TMDB's episode JSON — we inject it manually.
    }

    var stillURL: URL? { TMDBImage.url(path: stillPath, size: .w780) }
}

struct CreditsResponse: Codable {
    var cast: [CastMember]?
}

struct CastMember: Codable, Identifiable, Hashable {
    var id: Int
    var name: String
    var character: String?
    var profilePath: String?

    enum CodingKeys: String, CodingKey {
        case id, name, character
        case profilePath = "profile_path"
    }

    var profileURL: URL? { TMDBImage.url(path: profilePath, size: .w500) }

    /// TMDB person page, opened when a cast card is tapped — same as the
    /// Electron cast-card click handler. Non-optional so views don't have to
    /// force-unwrap; the id is always numeric so this cannot realistically fail.
    var tmdbPersonURL: URL {
        URL(string: "https://www.themoviedb.org/person/\(id)")
            ?? URL(string: "https://www.themoviedb.org")!
    }

    var initials: String {
        name.split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
            .map(String.init)
            .joined()
            .uppercased()
    }
}
