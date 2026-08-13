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
        StreamServer(name: "VixSrc",       base: "https://vixsrc.to"),
        StreamServer(name: "VidLink",      base: "https://vidlink.pro"),
        StreamServer(name: "VidSrc.mov",   base: "https://vidsrc.mov/embed"),
        StreamServer(name: "VidSrc.sbs",   base: "https://vidsrc.sbs/embed"),
        StreamServer(name: "VidSrc.wiki",  base: "https://vidsrc.wiki/embed"),
        StreamServer(name: "2Embed",       base: "https://www.2embed.stream/embed"),
        StreamServer(name: "2Embed.cc",    base: "https://www.2embed.cc/embed"),
        StreamServer(name: "MoviesApi",    base: "https://moviesapi.to"),
        StreamServer(name: "AutoEmbed",    base: "https://autoembed.co/movie/tmdb"),
        StreamServer(name: "NontonGo",     base: "https://nontongo.win/embed"),
        StreamServer(name: "VidPhantom",   base: "https://vidphantom.com"),
        StreamServer(name: "VidNest",      base: "https://vidnest.fun"),
        StreamServer(name: "HnEmbed",      base: "https://hnembed.com/embed"),
        StreamServer(name: "MovCloud",     base: "https://movcloud.net/embed"),
        StreamServer(name: "SmashyStream", base: "https://embed.smashystream.com/playere.php?tmdb"),
    ]
}

private extension String {
    var trimmedTrailingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
