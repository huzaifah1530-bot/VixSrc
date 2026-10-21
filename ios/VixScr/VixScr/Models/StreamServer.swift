import Foundation

/// A configurable streaming backend, e.g. VixSrc. Mirrors the
/// `DEFAULT_SERVERS` array and the "Manage backends" settings section.
///
/// Stremio stream addons (NebulaStreams) are stored the same way, with the
/// addon's manifest URL as `base` (…/manifest.json). StreamURLExtractor
/// recognises the `manifest.json/movie/…` route and asks the addon.
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

    static let nebulaStreams = StreamServer(name: "NebulaStreams", base: "https://nebula.work.gd/manifest.json")

    /// The original embed servers.
    static var embedDefaults: [StreamServer] {
        [
            StreamServer(name: "VixSrc", base: "https://vixsrc.to"),
            StreamServer(name: "ApiPlayer", base: "https://apiplayer.ru/embed"),
            StreamServer(name: "Cinezo", base: "https://player.cinezo.live/embed"),
            StreamServer(name: "Vidlink", base: "https://vidlink.pro"),
            StreamServer(name: "VidSrc", base: "https://vidsrc.wiki/embed"),
        ]
    }

    static let defaults: [StreamServer] = embedDefaults + [nebulaStreams]

    /// Drops the Nuvio provider servers earlier builds added, makes sure the
    /// embeds are present and adds NebulaStreams. Existing order is kept.
    static func migrated(_ servers: [StreamServer]) -> [StreamServer] {
        func norm(_ s: String) -> String { s.trimmedTrailingSlash.lowercased() }
        let kept = servers.filter { server in
            let b = server.base.lowercased()
            return !(b.contains("/nuvio-providers/") && b.contains("/providers/") && b.hasSuffix(".js"))
        }
        let have = Set(kept.map { norm($0.base) })
        return kept + (embedDefaults + [nebulaStreams]).filter { !have.contains(norm($0.base)) }
    }
}

/// `<addon>/manifest.json/movie/<tmdbId>` or `/tv/<tmdbId>/<season>/<episode>`.
struct AddonRoute: Hashable, Sendable {
    /// Addon root, without /manifest.json.
    let root: String
    let mediaType: String
    let tmdbId: String
    let season: Int?
    let episode: Int?

    static func isAddonURL(_ url: URL) -> Bool { AddonRoute(url: url) != nil || url.path.lowercased().hasSuffix("/manifest.json") }

    init?(url: URL) {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let i = parts.firstIndex(where: { $0.lowercased() == "manifest.json" }),
              parts.count > i + 2, let scheme = url.scheme, let host = url.host else { return nil }
        let type = parts[i + 1].lowercased()
        let id = parts[i + 2].removingPercentEncoding ?? parts[i + 2]
        switch type {
        case "movie":
            season = nil
            episode = nil
        case "tv":
            guard parts.count > i + 4, let s = Int(parts[i + 3]), let e = Int(parts[i + 4]) else { return nil }
            season = s
            episode = e
        default:
            return nil
        }
        let port = url.port.map { ":\($0)" } ?? ""
        let prefix = parts[..<i].map { "/" + $0 }.joined()
        root = "\(scheme)://\(host)\(port)\(prefix)"
        mediaType = type
        tmdbId = id
    }
}

private extension String {
    var trimmedTrailingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
