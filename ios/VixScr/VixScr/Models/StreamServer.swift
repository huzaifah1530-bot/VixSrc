import Foundation

/// A configurable streaming backend, e.g. VixSrc. Mirrors the
/// `DEFAULT_SERVERS` array and the "Manage backends" settings section.
struct StreamServer: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var base: String

    /// Builds `<base>/movie/<tmdbId>`.
    func movieURL(tmdbId: String) -> URL? {
        URL(string: base.trimmedTrailingSlash + "/movie/" + tmdbId)
    }

    /// Builds `<base>/tv/<tmdbId>/<season>/<episode>`.
    func tvURL(tmdbId: String, season: Int, episode: Int) -> URL? {
        URL(string: base.trimmedTrailingSlash + "/tv/\(tmdbId)/\(season)/\(episode)")
    }

    static let defaults: [StreamServer] = [
        StreamServer(name: "VixSrc", base: "https://vixsrc.to"),
        StreamServer(name: "ApiPlayer", base: "https://apiplayer.ru/embed")
    ]
}

private extension String {
    var trimmedTrailingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
