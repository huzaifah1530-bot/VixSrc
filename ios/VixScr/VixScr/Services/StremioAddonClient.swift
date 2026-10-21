import Foundation

/// Stremio stream addons (NebulaStreams): TMDB id → IMDb id →
/// `<addon>/stream/<type>/<id>.json`. Only direct HTTP streams are kept,
/// and each is probed so landing pages, dead links and formats AVPlayer
/// can't play (MKV/WebM) never reach the player. Mirrors desktop
/// src/main/resolvers/stremio.ts.
enum StremioAddonClient {
    private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"
    /// Headers belonging to the connection, never handed to the player.
    private static let hopHeaders: Set<String> = ["accept-encoding", "connection", "keep-alive", "host", "content-length", "transfer-encoding", "te", "upgrade"]

    static func streams(for route: AddonRoute) async -> [StreamURLExtractor.ResolvedStream] {
        let prefixes = await idPrefixes(root: route.root)
        let useTmdb = prefixes.map { !$0.contains("tt") && $0.contains("tmdb:") } ?? false
        let baseId: String
        if useTmdb {
            baseId = "tmdb:\(route.tmdbId)"
        } else {
            guard let imdb = await imdbId(type: route.mediaType, tmdbId: route.tmdbId) else { return [] }
            baseId = imdb
        }
        let id = route.mediaType == "tv" ? "\(baseId):\(route.season ?? 1):\(route.episode ?? 1)" : baseId
        let kind = route.mediaType == "tv" ? "series" : "movie"
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(route.root)/stream/\(kind)/\(encoded).json") else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 45)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let result = try? await URLSession.shared.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any],
              let list = json["streams"] as? [[String: Any]] else { return [] }

        let candidates: [(url: URL, name: String, headers: [String: String])] = list.prefix(30).compactMap { s in
            guard let raw = s["url"] as? String, let u = URL(string: raw), let scheme = u.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            let hints = s["behaviorHints"] as? [String: Any]
            let proxy = (hints?["proxyHeaders"] as? [String: Any])?["request"] as? [String: Any] ?? [:]
            var headers: [String: String] = [:]
            for (k, v) in proxy where !hopHeaders.contains(k.lowercased()) { headers[k] = "\(v)" }
            let title = (s["title"] as? String) ?? (s["description"] as? String) ?? (hints?["filename"] as? String) ?? ""
            let detail = title.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
            let name = ((s["name"] as? String) ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            let label = [name, detail].filter { !$0.isEmpty }.joined(separator: " · ")
            return (u, String((label.isEmpty ? "Stream" : label).prefix(140)), headers)
        }

        // Probe in parallel; keep order.
        let formats = await withTaskGroup(of: (Int, String?).self) { group in
            for (i, c) in candidates.enumerated() {
                group.addTask { (i, await probe(c.url, headers: c.headers)) }
            }
            var out = [String?](repeating: nil, count: candidates.count)
            for await (i, f) in group { out[i] = f }
            return out
        }
        return candidates.enumerated().compactMap { i, c in
            guard let f = formats[i], f == "hls" || f == "mp4" else { return nil }
            var headers = c.headers
            if headers["User-Agent"] == nil { headers["User-Agent"] = StreamURLExtractor.userAgent }
            return StreamURLExtractor.ResolvedStream(id: c.url.absoluteString, name: c.name, url: c.url, requestHeaders: headers)
        }
    }

    /// hls | mp4 | mkv | ts | webm, or nil when the URL doesn't serve video.
    private static func probe(_ url: URL, headers: [String: String]) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
        guard let result = try? await URLSession.shared.bytes(for: request),
              let http = result.1 as? HTTPURLResponse, (200..<400).contains(http.statusCode) else { return nil }
        var head = Data()
        do {
            for try await byte in result.0 {
                head.append(byte)
                if head.count >= 2048 { break }
            }
        } catch { return nil }
        result.0.task.cancel()
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let b = [UInt8](head)
        let text = String(decoding: b.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#EXTM3U") || text.hasPrefix("\u{FEFF}#EXTM3U") { return "hls" }
        if b.count >= 4, b[0] == 0x1a, b[1] == 0x45, b[2] == 0xdf, b[3] == 0xa3 { return type.contains("webm") ? "webm" : "mkv" }
        if b.count >= 8, String(decoding: b[4..<8], as: UTF8.self) == "ftyp" { return "mp4" }
        if b.count >= 189, b[0] == 0x47, b[188] == 0x47 { return "ts" }
        if type.contains("mpegurl") { return "hls" }
        if type.hasPrefix("video/mp4") || type.hasPrefix("video/quicktime") { return "mp4" }
        if type.contains("matroska") { return "mkv" }
        return nil
    }

    private static func idPrefixes(root: String) async -> [String]? {
        guard let url = URL(string: root + "/manifest.json") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let result = try? await URLSession.shared.data(for: request),
              let m = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any] else { return nil }
        let resources = m["resources"] as? [Any] ?? []
        let stream = resources.compactMap { $0 as? [String: Any] }.first { $0["name"] as? String == "stream" }
        return (stream?["idPrefixes"] as? [String]) ?? (m["idPrefixes"] as? [String])
    }

    /// TMDB external ids → IMDb id, using the TMDB key saved in Settings.
    private static func imdbId(type: String, tmdbId: String) async -> String? {
        let credential = (UserDefaults.standard.string(forKey: AppStore.Keys.credential) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty,
              var components = URLComponents(string: "https://api.themoviedb.org/3/\(type)/\(tmdbId)/external_ids") else { return nil }
        var request: URLRequest
        if credential.hasPrefix("eyJ") || credential.count > 60 {
            guard let url = components.url else { return nil }
            request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        } else {
            components.queryItems = [URLQueryItem(name: "api_key", value: credential)]
            guard let url = components.url else { return nil }
            request = URLRequest(url: url, timeoutInterval: 10)
        }
        guard let result = try? await URLSession.shared.data(for: request),
              let json = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any],
              let id = json["imdb_id"] as? String, id.hasPrefix("tt") else { return nil }
        return id
    }
}
