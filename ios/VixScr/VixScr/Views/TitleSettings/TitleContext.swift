import Foundation

/// An episode (or the movie itself) the segment recorder can open.
struct EpisodeRef: Hashable, Identifiable, Sendable {
    /// The progress key, e.g. `tv:1399:1:3`; the same key segment matches
    /// are remembered under.
    let id: String
    /// "S1 · E3", "Episode 3", or the movie's title.
    let label: String
    let title: String?
    let season: Int?
    let number: Int
    /// AnimeKai episode ids, needed to resolve an anime episode's streams.
    var animeIDs: String? = nil
}

/// What the title settings screens need from the player sheet that opened
/// them: the title, the player that's showing it (for its tracks and to
/// apply changes live), and ways to list and open episodes for recording.
@MainActor
struct TitleContext {
    let key: String
    let item: MediaItem
    let kind: TitleKind
    let playerManager: VideoPlayerManager
    /// TV seasons, in order. Empty for movies and anime.
    let seasons: [Int]
    let currentSeason: Int?
    let currentEpisode: EpisodeRef?
    /// Episodes of a season (TV), of the show (anime, season nil), or the
    /// movie itself.
    let loadEpisodes: @MainActor (Int?) async -> [EpisodeRef]
    /// A playable stream for an episode, from the current server first.
    let resolveStream: @MainActor (EpisodeRef) async -> StreamURLExtractor.ResolvedStream?
    /// Hands the saved settings to the playing video.
    let apply: @MainActor () -> Void

    var title: String { item.title }
}
