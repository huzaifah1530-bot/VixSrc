import Foundation
import CommonCrypto
import CryptoKit

/// Native port of the AnimeKai / AniKoto Mangayomi extension
/// (github.com/Mallyd11/mangayomi-anime-extensions, `anikoto.js`).
///
/// The sites have no TMDB mapping, so a TMDB title is matched to the site's
/// catalogue by name (and season number), then resolved down to HLS
/// playlists AVPlayer can play directly:
///
///   /filter?keyword=        search, pick the best title + season match
///   /watch/{slug}           read the internal anime id (#watch-main data-id)
///   /ajax/episode/list/{id} episode list with per-episode server `data-ids`
///   /ajax/server/list       sub / dub server groups with `data-link-id`s
///   /ajax/server?get=       embed URL (MegaPlay, VidTube, ...)
///   {host}/stream/getSources  AES-encrypted `enc` → master.m3u8 (+ VTT tracks)
///
/// The master playlist is then split into per-resolution variants, giving
/// "1080p · Dub", "720p · Sub", ... sources for the player's quality picker.
struct AnimeKaiClient {
    struct Request: Sendable {
        var base: String
        var tmdbId: String
        var title: String
        var isMovie: Bool
        var season: Int
        var episode: Int
        /// Episode number counted across every earlier season, for sites that
        /// list a long-running show (One Piece, Naruto) as one entry.
        var absoluteEpisode: Int?
    }

    enum ResolveError: LocalizedError {
        case notFound, episodeMissing, noStreams

        var errorDescription: String? {
            switch self {
            case .notFound: return "Couldn't find this title"
            case .episodeMissing: return "This episode isn't available yet"
            case .noStreams: return "No playable streams found"
            }
        }
    }

    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"

    // Constants MegaPlay's own player ships in the clear (see anikoto.js).
    private static let encKey = "i?LMTAx0Q6,:}50U"
    private static let encIV = "W0;27ToaUpl_P%'c"
    private static let cdnSecret = "MpCdnT0k3n!9f2K#xQ7vL5mR8wN1pY4s"
    private static let tokenTTL = 21_600

    /// Server name prefixes in the order the extension prefers them. VidPlay's
    /// CDN is the one that reliably outruns playback.
    private static let serverOrder = ["vidplay", "hd", "vidstream", "vidcloud"]

    private static let cache = AnimeKaiCache()

    // MARK: - Public entry point

    static func streams(for request: Request) async throws -> [StreamURLExtractor.ResolvedStream] {
        let base = request.base.hasSuffix("/") ? String(request.base.dropLast()) : request.base
        let seasonKey = request.isMovie ? 0 : request.season
        let cacheKey = "\(base)|\(request.tmdbId)|\(seasonKey)"

        var entry = await cache.entry(for: cacheKey)
        if entry == nil {
            guard let match = try await findTitle(base: base, request: request) else { throw ResolveError.notFound }
            let episodes = try await episodeList(base: base, slug: match.slug)
            guard !episodes.isEmpty else { throw ResolveError.notFound }
            let resolved = AnimeKaiCache.Entry(slug: match.slug, usesAbsoluteNumbering: match.usesAbsoluteNumbering, episodes: episodes)
            await cache.store(resolved, for: cacheKey)
            entry = resolved
        }
        guard let entry else { throw ResolveError.notFound }

        let wanted: Int
        if request.isMovie {
            wanted = 1
        } else if entry.usesAbsoluteNumbering, let absolute = request.absoluteEpisode {
            wanted = absolute
        } else {
            wanted = request.episode
        }
        let episode = entry.episodes.first { $0.number == String(wanted) }
            ?? request.absoluteEpisode.flatMap { abs in entry.episodes.first { $0.number == String(abs) } }
            ?? (request.isMovie ? entry.episodes.first : nil)
        guard let episode, !episode.ids.isEmpty else { throw ResolveError.episodeMissing }

        // Server link ids rotate, so always fetch a fresh server list.
        let groups = try await serverGroups(base: base, ids: episode.ids)
        async let sub = resolveTrack(base: base, servers: groups.sub, audio: "Sub")
        async let dub = resolveTrack(base: base, servers: groups.dub, audio: "Dub")
        let all = await sub + dub
        guard !all.isEmpty else { throw ResolveError.noStreams }
        return all.map(\.resolved)
    }

    /// Sendable stand-in for `ResolvedStream` (which carries non-Sendable
    /// HTTPCookies) so sub and dub can resolve concurrently.
    private struct AnimeStream: Sendable {
        var url: URL
        var headers: [String: String]
        var audio: String
        var quality: String
        var subtitles: [ExternalSubtitle]

        var resolved: StreamURLExtractor.ResolvedStream {
            StreamURLExtractor.ResolvedStream(
                id: "\(audio)|\(url.absoluteString)",
                name: "\(quality) · \(audio)",
                url: url,
                requestHeaders: headers,
                audio: audio,
                quality: quality,
                subtitles: subtitles
            )
        }
    }

    // MARK: - Title matching

    private struct Candidate {
        var slug: String
        var name: String
        var japaneseName: String
        var kind: String
    }

    private struct Match {
        var slug: String
        var usesAbsoluteNumbering: Bool
    }

    private static func findTitle(base: String, request: Request) async throws -> Match? {
        let results = try await search(base: base, query: request.title)

        if request.isMovie {
            let ranked = rank(results, title: request.title, season: nil)
            let movies = ranked.filter { $0.candidate.kind.uppercased() == "MOVIE" }
            return (movies.first ?? ranked.first).map { Match(slug: $0.candidate.slug, usesAbsoluteNumbering: false) }
        }

        let ranked = rank(results, title: request.title, season: request.season)
        if let exact = ranked.first(where: { seasonNumber(in: $0.candidate.name) == request.season && $0.candidate.kind.uppercased() != "MOVIE" }) {
            return Match(slug: exact.candidate.slug, usesAbsoluteNumbering: false)
        }

        if request.season > 1 {
            // Later seasons are usually separate entries ("... Season 2").
            let more = try await search(base: base, query: "\(request.title) season \(request.season)")
            let reranked = rank(more, title: request.title, season: request.season)
            if let exact = reranked.first(where: { seasonNumber(in: $0.candidate.name) == request.season }) {
                return Match(slug: exact.candidate.slug, usesAbsoluteNumbering: false)
            }
            // No separate entry: assume one continuous listing.
            if let single = ranked.first(where: { seasonNumber(in: $0.candidate.name) == 1 && $0.candidate.kind.uppercased() == "TV" }) ?? ranked.first {
                return Match(slug: single.candidate.slug, usesAbsoluteNumbering: true)
            }
        }
        return nil
    }

    private static func rank(_ candidates: [Candidate], title: String, season: Int?) -> [(candidate: Candidate, score: Double)] {
        let target = normalize(stripSeason(title))
        return candidates
            .map { candidate -> (Candidate, Double) in
                let english = similarity(target, normalize(stripSeason(candidate.name)))
                let japanese = similarity(target, normalize(stripSeason(candidate.japaneseName)))
                var score = max(english, japanese)
                if candidate.kind.uppercased() == "TV" { score += 0.05 }
                return (candidate, score)
            }
            .filter { $0.1 >= 0.5 }
            .sorted { $0.1 > $1.1 }
            .map { (candidate: $0.0, score: $0.1) }
    }

    private static func search(base: String, query: String) async throws -> [Candidate] {
        var components = URLComponents(string: base + "/filter")
        components?.queryItems = [URLQueryItem(name: "keyword", value: query)]
        guard let url = components?.url else { return [] }
        let html = try await getString(url, headers: ["User-Agent": userAgent, "Referer": base + "/"])

        // Each result card has a `d-title` anchor (name, href, data-jp),
        // followed by meta labels including the type ("TV", "Movie", "OVA").
        var out: [Candidate] = []
        guard let regex = try? NSRegularExpression(pattern: #"<a\b[^>]*\bd-title\b[^>]*>[\s\S]*?</a>"#, options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            guard let href = attribute("href", in: tag),
                  let slug = firstMatch(#"/(?:watch|anime)/([^/?#"]+)"#, in: href, group: 1) else { continue }
            let name = decodeEntities(stripTags(firstMatch(#">([\s\S]*?)</a>"#, in: tag, group: 1) ?? ""))
            let jp = decodeEntities(attribute("data-jp", in: tag) ?? "")
            let tail = ns.substring(with: NSRange(location: match.range.location, length: min(2500, ns.length - match.range.location)))
            let kind = firstMatch(#"<label>\s*(TV|MOVIE|OVA|ONA|SPECIAL|MUSIC)\s*</label>"#, in: tail, group: 1) ?? ""
            guard !name.isEmpty, !out.contains(where: { $0.slug == slug }) else { continue }
            out.append(Candidate(slug: slug, name: name, japaneseName: jp, kind: kind))
        }
        return out
    }

    // MARK: - Episodes and servers

    private static func episodeList(base: String, slug: String) async throws -> [AnimeKaiCache.Episode] {
        guard let watchURL = URL(string: base + "/watch/" + slug) else { return [] }
        let html = try await getString(watchURL, headers: ["User-Agent": userAgent, "Referer": base + "/"])
        guard let animeId = firstMatch(#"id="watch-main"[^>]*data-id="(\d+)""#, in: html, group: 1)
                ?? firstMatch(#"data-id="(\d+)"[^>]*id="watch-main""#, in: html, group: 1),
              let listURL = URL(string: base + "/ajax/episode/list/" + animeId + "?vrf=") else { return [] }

        let body = try await getString(listURL, headers: xhrHeaders(referer: watchURL.absoluteString + "/"))
        let listHTML = resultHTML(from: body)

        var episodes: [AnimeKaiCache.Episode] = []
        for tag in allMatches(#"<a\b[^>]*\bdata-num="[^"]*"[^>]*>"#, in: listHTML) {
            guard let num = attribute("data-num", in: tag), let ids = attribute("data-ids", in: tag),
                  !episodes.contains(where: { $0.number == num }) else { continue }
            episodes.append(AnimeKaiCache.Episode(number: num, ids: ids))
        }
        return episodes
    }

    private struct ServerEntry {
        var linkId: String
        var name: String
    }

    private static func serverGroups(base: String, ids: String) async throws -> (sub: [ServerEntry], dub: [ServerEntry]) {
        var components = URLComponents(string: base + "/ajax/server/list")
        components?.queryItems = [URLQueryItem(name: "servers", value: ids)]
        guard let url = components?.url else { return ([], []) }
        let html = resultHTML(from: try await getString(url, headers: xhrHeaders(referer: base + "/")))

        // Split on each `.type[data-type]` container.
        var sections: [(type: String, body: String)] = []
        let pattern = try NSRegularExpression(pattern: #"data-type="([a-z]+)""#)
        let ns = html as NSString
        let matches = pattern.matches(in: html, range: NSRange(location: 0, length: ns.length))
        for (index, match) in matches.enumerated() {
            let start = match.range.location
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            sections.append((ns.substring(with: match.range(at: 1)), ns.substring(with: NSRange(location: start, length: end - start))))
        }
        if sections.isEmpty { sections = [("sub", html)] }

        func entries(in body: String) -> [ServerEntry] {
            var out: [ServerEntry] = []
            for li in allMatches(#"<li\b[^>]*data-link-id="[^"]+"[^>]*>[\s\S]*?</li>"#, in: body) {
                guard let linkId = attribute("data-link-id", in: li) else { continue }
                let name = decodeEntities(stripTags(firstMatch(#">([\s\S]*?)</li>"#, in: li, group: 1) ?? ""))
                out.append(ServerEntry(linkId: linkId, name: name))
            }
            return out.sorted { order(of: $0.name) < order(of: $1.name) }
        }

        // Soft subs ("sub") first — their VTT tracks are rendered natively —
        // then hard subs ("hsub"/"softsub" variants) as a fallback.
        let subTypes = ["sub", "softsub", "hsub"]
        let sub = subTypes.flatMap { type in sections.filter { $0.type == type }.flatMap { entries(in: $0.body) } }
        let dub = sections.filter { $0.type == "dub" }.flatMap { entries(in: $0.body) }
        return (sub, dub)
    }

    private static func order(of serverName: String) -> Int {
        let lower = serverName.lowercased()
        return serverOrder.firstIndex { lower.hasPrefix($0) } ?? serverOrder.count
    }

    /// Walks one audio track's servers until one yields playable streams.
    private static func resolveTrack(base: String, servers: [ServerEntry], audio: String) async -> [AnimeStream] {
        for server in servers.prefix(6) {
            if let streams = try? await resolveServer(base: base, linkId: server.linkId, audio: audio), !streams.isEmpty {
                return streams
            }
        }
        return []
    }

    private static func resolveServer(base: String, linkId: String, audio: String) async throws -> [AnimeStream] {
        var components = URLComponents(string: base + "/ajax/server")
        components?.queryItems = [URLQueryItem(name: "get", value: linkId)]
        guard let url = components?.url else { return [] }
        let data = try await getData(url, headers: xhrHeaders(referer: base + "/"))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        var embed = ""
        if let result = json["result"] as? String { embed = result }
        else if let result = json["result"] as? [String: Any] {
            embed = (result["url"] as? String) ?? (result["link"] as? String) ?? ""
        }
        guard !embed.isEmpty else { return [] }

        if let streamId = firstMatch(#"/stream/s-\d+/(\d+)/(?:sub|dub)"#, in: embed, group: 1) {
            return try await megaPlayStreams(embed: embed, fallbackId: streamId, base: base, audio: audio)
        }
        if embed.contains("vidtube.site/stream/") {
            return try await vidTubeStreams(embed: embed, base: base, audio: audio)
        }
        if embed.contains(".m3u8"), let direct = URL(string: embed) {
            return try await variants(master: direct, referer: base + "/", audio: audio, subtitles: [])
        }
        return []
    }

    // MARK: - Hosts

    private static func megaPlayStreams(embed: String, fallbackId: String, base: String, audio: String) async throws -> [AnimeStream] {
        guard let embedURL = URL(string: embed), let scheme = embedURL.scheme, let hostName = embedURL.host else { return [] }
        let host = "\(scheme)://\(hostName)"

        // The id in the embed path is a routing key; the real getSources id
        // lives in the embed page's HTML.
        var sourceId = fallbackId
        if let page = try? await getString(embedURL, headers: ["User-Agent": userAgent, "Referer": base + "/"]),
           let id = firstMatch(#"data-id="(\d+)""#, in: page, group: 1) ?? firstMatch(#"<title>File (\d+)"#, in: page, group: 1) {
            sourceId = id
        }
        guard let sourcesURL = URL(string: host + "/stream/getSources?id=" + sourceId) else { return [] }
        var headers = xhrHeaders(referer: host + "/")
        headers["Accept"] = "application/json"
        let data = try await getData(sourcesURL, headers: headers)
        return try await streams(fromSources: data, referer: host + "/", audio: audio)
    }

    private static func vidTubeStreams(embed: String, base: String, audio: String) async throws -> [AnimeStream] {
        guard let embedURL = URL(string: embed) else { return [] }
        let page = try await getString(embedURL, headers: ["User-Agent": userAgent, "Referer": base + "/"])
        guard let fileId = firstMatch(#"getSourcesNew\?id=(\d+)"#, in: page, group: 1) ?? firstMatch(#"<title>File (\d+)"#, in: page, group: 1) else { return [] }
        let type = firstMatch(#"/(sub|dub)(?:[?#]|$)"#, in: embed, group: 1) ?? "sub"
        guard let url = URL(string: "https://vidtube.site/stream/getSourcesNew?id=\(fileId)&type=\(type)") else { return [] }
        let data = try await getData(url, headers: xhrHeaders(referer: "https://vidtube.site/"))
        return try await streams(fromSources: data, referer: "https://vidtube.site/", audio: audio)
    }

    private static func streams(fromSources data: Data, referer: String, audio: String) async throws -> [AnimeStream] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var file = playlistURL(from: json["sources"]) ?? ""
        if file.isEmpty, let enc = json["enc"] as? String { file = decryptSources(enc) ?? "" }
        guard !file.isEmpty, let master = URL(string: signCDNURL(file)) else { return [] }

        let tracks = (json["tracks"] as? [[String: Any]] ?? []).compactMap { track -> ExternalSubtitle? in
            guard (track["kind"] as? String) != "thumbnails",
                  let file = track["file"] as? String, let url = URL(string: file) else { return nil }
            return ExternalSubtitle(label: track["label"] as? String ?? "Subtitles", url: url, referer: referer)
        }
        // Dubs carry an English track too; it's still useful (signs/songs),
        // so it's offered but the player only auto-enables it for subs.
        return try await variants(master: master, referer: referer, audio: audio, subtitles: tracks)
    }

    private static func playlistURL(from value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        if let dict = value as? [String: Any] { return (dict["file"] as? String) ?? (dict["url"] as? String) ?? playlistURL(from: dict["sources"]) }
        if let array = value as? [Any], let first = array.first { return playlistURL(from: first) }
        return nil
    }

    /// Splits a master playlist into "Auto" (adaptive) plus one source per
    /// resolution, highest first.
    private static func variants(master: URL, referer: String, audio: String, subtitles: [ExternalSubtitle]) async throws -> [AnimeStream] {
        let headers = ["User-Agent": userAgent, "Referer": referer]
        let body = try await getString(master, headers: headers)
        guard body.contains("#EXTM3U") else { return [] }

        func make(_ url: URL, _ quality: String) -> AnimeStream {
            AnimeStream(url: url, headers: headers, audio: audio, quality: quality, subtitles: subtitles)
        }

        var out = [make(master, "Auto")]
        guard body.contains("#EXT-X-STREAM-INF") else { return out }

        var levels: [(height: Int, url: URL)] = []
        let lines = body.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        for (index, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF:") {
            guard let height = firstMatch(#"RESOLUTION=\d+x(\d+)"#, in: line, group: 1).flatMap(Int.init),
                  let uri = lines[(index + 1)...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                  let url = URL(string: uri, relativeTo: master)?.absoluteURL,
                  !levels.contains(where: { $0.height == height }) else { continue }
            levels.append((height, url))
        }
        out += levels.sorted { $0.height > $1.height }.map { make($0.url, "\($0.height)p") }
        return out
    }

    // MARK: - MegaPlay crypto

    /// `enc` is AES-256-CBC (key zero-padded to 32 bytes) over the JSON that
    /// used to sit in `sources`.
    private static func decryptSources(_ enc: String) -> String? {
        guard var cipher = base64URLDecode(enc) else { return nil }
        cipher = cipher.prefix(cipher.count - cipher.count % 16)
        guard !cipher.isEmpty else { return nil }

        var key = Array(encKey.utf8)
        key += Array(repeating: 0, count: max(0, 32 - key.count))
        var iv = Array(encIV.utf8)
        iv += Array(repeating: 0, count: max(0, 16 - iv.count))

        var output = [UInt8](repeating: 0, count: cipher.count)
        var outLength = 0
        let status = cipher.withUnsafeBytes { cipherPtr in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                    key, 32, iv,
                    cipherPtr.baseAddress, cipher.count,
                    &output, output.count, &outLength)
        }
        guard status == kCCSuccess else { return nil }
        var plain = Array(output.prefix(outLength))
        if let pad = plain.last, (1...16).contains(Int(pad)), plain.count >= Int(pad),
           plain.suffix(Int(pad)).allSatisfy({ $0 == pad }) {
            plain.removeLast(Int(pad))
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(plain), options: .fragmentsAllowed) else { return nil }
        return playlistURL(from: object)
    }

    /// The CDN refuses a master playlist without
    /// `token=b64url("<expiry>|<id1>/<id2>").b64url(HMAC-SHA256)`.
    private static func signCDNURL(_ url: String) -> String {
        guard url.range(of: #"[?&]token="#, options: .regularExpression) == nil,
              let id1 = firstMatch(#"/([a-fA-F0-9]{32})/([a-fA-F0-9]{32})/"#, in: url, group: 1),
              let id2 = firstMatch(#"/([a-fA-F0-9]{32})/([a-fA-F0-9]{32})/"#, in: url, group: 2) else { return url }
        let expiry = Int(Date().timeIntervalSince1970) + tokenTTL
        let message = "\(expiry)|\(id1.lowercased())/\(id2.lowercased())"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(cdnSecret.utf8)))
        let token = base64URLEncode(Data(message.utf8)) + "." + base64URLEncode(Data(mac))
        return url + (url.contains("?") ? "&" : "?") + "token=" + token
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s = s.filter { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || $0 == "+" || $0 == "/" }
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    // MARK: - HTTP

    private static func xhrHeaders(referer: String) -> [String: String] {
        [
            "User-Agent": userAgent,
            "Referer": referer,
            "X-Requested-With": "XMLHttpRequest",
            "Accept": "application/json, text/javascript, */*; q=0.01",
        ]
    }

    private static func getData(_ url: URL, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func getString(_ url: URL, headers: [String: String]) async throws -> String {
        let data = try await getData(url, headers: headers)
        return String(decoding: data, as: UTF8.self)
    }

    /// AJAX endpoints wrap their HTML as `{ "status": 200, "result": "<html>" }`.
    private static func resultHTML(from body: String) -> String {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let result = json["result"] as? String {
            return result
        }
        return body
    }

    // MARK: - Text helpers

    private static func firstMatch(_ pattern: String, in text: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > group,
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        firstMatch("\\b" + NSRegularExpression.escapedPattern(for: name) + #"="([^"]*)""#, in: tag, group: 1)
    }

    private static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ text: String) -> String {
        var out = text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        while let range = out.range(of: #"&#(\d+);"#, options: .regularExpression) {
            let digits = out[range].dropFirst(2).dropLast()
            let scalar = UInt32(digits).flatMap(Unicode.Scalar.init).map(String.init) ?? ""
            out.replaceSubrange(range, with: scalar)
        }
        return out
    }

    /// Season number a site title advertises: "Season 2", "2nd Season",
    /// "Part 2" style suffixes, or a trailing roman numeral. 1 when absent.
    static func seasonNumber(in title: String) -> Int {
        let lower = title.lowercased()
        if let n = firstMatch(#"season\s*(\d+)"#, in: lower, group: 1).flatMap(Int.init) { return n }
        if let n = firstMatch(#"(\d+)(?:st|nd|rd|th)\s+season"#, in: lower, group: 1).flatMap(Int.init) { return n }
        if let roman = firstMatch(#"\s(ii|iii|iv|v|vi)$"#, in: lower, group: 1) {
            return ["ii": 2, "iii": 3, "iv": 4, "v": 5, "vi": 6][roman] ?? 1
        }
        return 1
    }

    private static func stripSeason(_ title: String) -> String {
        title
            .replacingOccurrences(of: #"(?i)\bseason\s*\d+\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\b\d+(st|nd|rd|th)\s+season\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s(ii|iii|iv|v|vi)$"#, with: "", options: .regularExpression)
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Token overlap (Dice coefficient) with a bonus for one title fully
    /// containing the other, e.g. "Frieren" vs "Frieren Beyond Journey's End".
    private static func similarity(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        let ta = Set(a.split(separator: " ")), tb = Set(b.split(separator: " "))
        let dice = 2 * Double(ta.intersection(tb).count) / Double(ta.count + tb.count)
        let contains = (b.hasPrefix(a + " ") || a.hasPrefix(b + " ")) ? 0.3 : 0
        return min(0.99, dice + contains)
    }
}

/// Title → site entry mappings, so moving between episodes skips the search.
private actor AnimeKaiCache {
    struct Episode: Sendable {
        var number: String
        var ids: String
    }

    struct Entry: Sendable {
        var slug: String
        var usesAbsoluteNumbering: Bool
        var episodes: [Episode]
    }

    private var entries: [String: Entry] = [:]

    func entry(for key: String) -> Entry? { entries[key] }
    func store(_ entry: Entry, for key: String) { entries[key] = entry }
}
