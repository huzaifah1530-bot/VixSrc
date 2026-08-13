import Foundation

/// Mirrors the `normalizeItem()` shape from index.html — a movie or TV show
/// normalized from a raw TMDB API response into the shape the rest of the
/// app works with.
struct MediaItem: Identifiable, Codable, Hashable {
    enum MediaType: String, Codable {
        case movie
        case tv
    }

    var tmdbId: String
    var type: MediaType
    var title: String
    var description: String
    var posterPath: String?
    var backdropPath: String?
    var rating: Double?
    var year: String
    var popularity: Double

    // "Continue watching" resume metadata (only present on recents).
    var resumeSeason: Int?
    var resumeEpisode: Int?
    var resumeTitle: String?
    var updatedAt: Date?

    var id: String { "\(type.rawValue):\(tmdbId)" }

    var posterURL: URL? { TMDBImage.url(path: posterPath, size: .w500) }
    var backdropURL: URL? { TMDBImage.url(path: backdropPath, size: .original) }

    var typeLabel: String { type == .movie ? "Movie" : "TV" }
}

enum TMDBImage {
    enum Size: String {
        case w500
        case w780
        case original
    }

    static func url(path: String?, size: Size) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size.rawValue)\(path)")
    }
}

/// A horizontally scrolling shelf of items, e.g. "Trending this week".
struct MediaRow: Identifiable {
    var id: String { title }
    var title: String
    var subtitle: String
    var items: [MediaItem]
}
