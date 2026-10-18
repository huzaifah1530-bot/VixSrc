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
    
    // Watch progress tracking
    var resumePosition: Double?
    var duration: Double?

    /// Set from TMDB metadata (see `AnimeClassifier`). Optional so items
    /// saved by older builds still decode.
    var anime: Bool?
    var isAnime: Bool { anime == true }
    
    var progress: Double? {
        guard let position = resumePosition, let dur = duration, dur > 0 else { return nil }
        return position / dur
    }

    var id: String { "\(type.rawValue):\(tmdbId)" }

    var posterURL: URL? { TMDBImage.url(path: posterPath, size: .w500) }
    var backdropURL: URL? { TMDBImage.url(path: backdropPath, size: .original) }

    /// Anime-tab titles come from the anime site's catalogue, not TMDB.
    /// They're stored as `kai:<slug>` so every existing card, favourite and
    /// progress view works unchanged.
    static let animeCatalogPrefix = "kai:"
    var isAnimeCatalog: Bool { tmdbId.hasPrefix(Self.animeCatalogPrefix) }
    var animeSlug: String? { isAnimeCatalog ? String(tmdbId.dropFirst(Self.animeCatalogPrefix.count)) : nil }

    static func anime(_ show: AnimeKaiClient.Show, description: String = "") -> MediaItem {
        var counts: [String] = []
        if let sub = show.subCount, sub > 0 { counts.append("Sub \(sub)") }
        if let dub = show.dubCount, dub > 0 { counts.append("Dub \(dub)") }
        return MediaItem(
            tmdbId: animeCatalogPrefix + show.slug,
            type: .tv,
            title: show.title,
            description: description.isEmpty ? (show.japaneseTitle.isEmpty ? show.title : show.japaneseTitle) : description,
            posterPath: show.posterURL,
            backdropPath: show.posterURL,
            rating: nil,
            year: counts.isEmpty ? show.kind : counts.joined(separator: " · "),
            popularity: 0,
            anime: true
        )
    }

    var typeLabel: String {
        if isAnime { return "Anime" }
        return type == .movie ? "Movie" : "TV"
    }
}

/// TMDB has no anime media type, so anime is inferred: Animation genre (16)
/// plus Japanese original language or Japanese origin. A heuristic — some
/// titles with incomplete metadata will be missed.
enum AnimeClassifier {
    static let animationGenreId = 16

    static func isAnime(genreIds: [Int]?, originalLanguage: String?, originCountry: [String]?) -> Bool {
        guard genreIds?.contains(animationGenreId) == true else { return false }
        return originalLanguage == "ja" || originCountry?.contains("JP") == true
    }
}

enum TMDBImage {
    enum Size: String {
        case w500
        case w780
        case original
    }

    static func url(path: String?, size: Size) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http") { return URL(string: path) }
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
