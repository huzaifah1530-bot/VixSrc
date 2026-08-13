import Foundation

/// Raw shape of a single result inside `/trending`, `/movie/popular`,
/// `/search/multi`, etc. `mediaType` is only present on `/trending` and
/// `/search/multi`; for type-specific endpoints we pass the type in
/// explicitly (mirrors `normalizeItem(item, forcedType)`).
struct TMDBRawItem: Codable {
    var id: Int
    var title: String?
    var name: String?
    var overview: String?
    var posterPath: String?
    var backdropPath: String?
    var voteAverage: Double?
    var popularity: Double?
    var releaseDate: String?
    var firstAirDate: String?
    var mediaType: String?

    enum CodingKeys: String, CodingKey {
        case id, title, name, overview
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case voteAverage = "vote_average"
        case popularity
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case mediaType = "media_type"
    }

    func normalized(forcedType: MediaItem.MediaType? = nil) -> MediaItem? {
        let type: MediaItem.MediaType
        if let forcedType {
            type = forcedType
        } else if mediaType == "movie" {
            type = .movie
        } else if mediaType == "tv" {
            type = .tv
        } else {
            return nil
        }

        let resolvedTitle = type == .movie ? title : name
        guard let resolvedTitle, !resolvedTitle.isEmpty else { return nil }

        let dateString = releaseDate ?? firstAirDate ?? ""
        let year = dateString.count >= 4 ? String(dateString.prefix(4)) : ""

        return MediaItem(
            tmdbId: String(id),
            type: type,
            title: resolvedTitle,
            description: (overview?.isEmpty == false) ? overview! : "No overview is available from TMDB for this title.",
            posterPath: posterPath,
            backdropPath: backdropPath ?? posterPath,
            rating: voteAverage,
            year: year,
            popularity: popularity ?? 0
        )
    }
}

struct TMDBListResponse: Codable {
    var results: [TMDBRawItem]?
}

/// `/movie/{id}` or `/tv/{id}` detail response, used for deep-linked opens
/// where we don't already have a normalized item (mirrors
/// `openContentByTmdbId`).
struct TMDBDetailResponse: Codable {
    var id: Int
    var title: String?
    var name: String?
    var overview: String?
    var posterPath: String?
    var backdropPath: String?
    var voteAverage: Double?
    var popularity: Double?
    var releaseDate: String?
    var firstAirDate: String?

    enum CodingKeys: String, CodingKey {
        case id, title, name, overview
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case voteAverage = "vote_average"
        case popularity
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
    }

    func normalized(type: MediaItem.MediaType) -> MediaItem? {
        let resolvedTitle = type == .movie ? title : name
        guard let resolvedTitle, !resolvedTitle.isEmpty else { return nil }
        let dateString = releaseDate ?? firstAirDate ?? ""
        let year = dateString.count >= 4 ? String(dateString.prefix(4)) : ""
        return MediaItem(
            tmdbId: String(id),
            type: type,
            title: resolvedTitle,
            description: (overview?.isEmpty == false) ? overview! : "No overview is available from TMDB for this title.",
            posterPath: posterPath,
            backdropPath: backdropPath ?? posterPath,
            rating: voteAverage,
            year: year,
            popularity: popularity ?? 0
        )
    }
}

struct TMDBErrorResponse: Codable {
    var statusMessage: String?

    enum CodingKeys: String, CodingKey {
        case statusMessage = "status_message"
    }
}
