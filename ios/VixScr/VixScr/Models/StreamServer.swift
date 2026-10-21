import Foundation

/// A configurable streaming backend, e.g. VixSrc. Mirrors the
/// `DEFAULT_SERVERS` array and the "Manage backends" settings section.
///
/// Nuvio providers are stored the same way, with the provider script's URL
/// as `base` (…/providers/xprime.js). StreamURLExtractor recognises the
/// `.js/movie/…` route and runs the bundled provider (NuvioRuntime).
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

    var isNuvio: Bool { URL(string: base).map(NuvioRoute.isProviderURL) ?? false }

    /// The original embed servers, kept ahead of the Nuvio providers.
    static var embedDefaults: [StreamServer] {
        [
            StreamServer(name: "VixSrc", base: "https://vixsrc.to"),
            StreamServer(name: "ApiPlayer", base: "https://apiplayer.ru/embed"),
            StreamServer(name: "Cinezo", base: "https://player.cinezo.live/embed"),
            StreamServer(name: "Vidlink", base: "https://vidlink.pro"),
            StreamServer(name: "VidSrc", base: "https://vidsrc.wiki/embed"),
        ]
    }

    static let defaults: [StreamServer] = embedDefaults
        + NuvioProviders.all.map { StreamServer(name: $0.name, base: $0.base) }

    /// Adds the Nuvio providers after the user's servers and brings back
    /// ApiPlayer / Cinezo / Vidlink if an earlier build removed them, each
    /// only when missing. Nuvio's "Vidlink" is renamed so names don't clash.
    static func migratedForNuvio(_ servers: [StreamServer]) -> [StreamServer] {
        func norm(_ s: String) -> String { s.trimmedTrailingSlash.lowercased() }
        let renamed = servers.map { server -> StreamServer in
            var s = server
            if s.name == "Vidlink", s.base.lowercased().hasSuffix("/providers/vidlink.js") { s.name = "Vidlink (Nuvio)" }
            return s
        }
        let have = Set(renamed.map { norm($0.base) })
        let embeds = embedDefaults.filter { !have.contains(norm($0.base)) }
        var merged = renamed
        if let firstNuvio = renamed.firstIndex(where: { $0.isNuvio }) {
            merged.insert(contentsOf: embeds, at: firstNuvio)
        } else {
            merged += embeds
        }
        let now = Set(merged.map { norm($0.base) })
        return merged + NuvioProviders.all
            .filter { !now.contains(norm($0.base)) }
            .map { StreamServer(name: $0.name, base: $0.base) }
    }
}

/// `<…>/providers/<file>.js/movie/<id>` or `/tv/<id>/<season>/<episode>`.
struct NuvioRoute: Hashable, Sendable {
    let provider: NuvioProvider
    let mediaType: String
    let tmdbId: String
    let season: Int?
    let episode: Int?

    /// Index of the `<file>.js` path component directly after `providers`.
    private static func scriptIndex(_ parts: [String]) -> Int? {
        guard let i = parts.firstIndex(where: { $0.lowercased().hasSuffix(".js") }),
              i > 0, parts[i - 1].lowercased() == "providers" else { return nil }
        return i
    }

    static func isProviderURL(_ url: URL) -> Bool {
        scriptIndex(url.pathComponents.filter { $0 != "/" }) != nil
    }

    init?(url: URL) {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let i = Self.scriptIndex(parts),
              let provider = NuvioProviders.all.first(where: { $0.file.lowercased() == parts[i].lowercased() }),
              parts.count > i + 2 else { return nil }
        let type = parts[i + 1].lowercased()
        let id = parts[i + 2].removingPercentEncoding ?? parts[i + 2]
        switch type {
        case "movie":
            self.season = nil
            self.episode = nil
        case "tv":
            guard parts.count > i + 4, let s = Int(parts[i + 3]), let e = Int(parts[i + 4]) else { return nil }
            self.season = s
            self.episode = e
        default:
            return nil
        }
        self.provider = provider
        self.mediaType = type
        self.tmdbId = id
    }
}

private extension String {
    var trimmedTrailingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
