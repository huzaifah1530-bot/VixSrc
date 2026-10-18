import Foundation

/// An anime streaming backend that speaks the AnimeKai / AniKoto site
/// protocol (`/filter`, `/watch/{slug}`, `/ajax/episode/list`,
/// `/ajax/server/list`, `/ajax/server`). Unlike `StreamServer` these cannot
/// be addressed by TMDB id, so playback goes through `AnimeKaiClient`, which
/// maps a TMDB title to the site's own catalogue by name.
struct AnimeServer: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var base: String

    var baseURL: String {
        base.hasSuffix("/") ? String(base.dropLast()) : base
    }

    static let defaults: [AnimeServer] = [
        AnimeServer(name: "AnimeKai", base: "https://animekaitv.to"),
        AnimeServer(name: "AniKoto", base: "https://anikototv.to"),
    ]
}

/// Which list the player's current server comes from. Both lists share one
/// dropdown in the player, split by a separator.
enum ServerSelection: Hashable {
    case regular(Int)
    case anime(Int)
}
