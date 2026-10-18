import Foundation

/// Extracts direct video URLs from streaming server responses.
/// For servers that return direct video URLs or have extractable patterns.
struct StreamURLExtractor {

    struct ResolvedStream: Identifiable, Hashable {
        let id: String
        let name: String
        let url: URL
        var requestHeaders: [String: String] = [:]
        var httpCookies: [HTTPCookie] = []
        /// Anime sources only: "Sub" or "Dub", and a "1080p"-style height label.
        var audio: String? = nil
        var quality: String? = nil
        /// Side-loaded WebVTT tracks (anime soft subs). AVPlayer cannot attach
        /// these to an HLS item, so VideoPlayerManager renders them itself.
        var subtitles: [ExternalSubtitle] = []

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id && lhs.name == rhs.name && lhs.url == rhs.url &&
                lhs.requestHeaders == rhs.requestHeaders && cookieKeys(lhs.httpCookies) == cookieKeys(rhs.httpCookies)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
            hasher.combine(name)
            hasher.combine(url)
            for (key, value) in requestHeaders.sorted(by: { $0.key < $1.key }) {
                hasher.combine(key)
                hasher.combine(value)
            }
            for cookie in Self.cookieKeys(httpCookies) { hasher.combine(cookie) }
        }

        private static func cookieKeys(_ cookies: [HTTPCookie]) -> [String] {
            cookies.map { "\($0.domain)|\($0.path)|\($0.name)|\($0.value)" }.sorted()
        }
    }
    
    /// Attempts to extract a direct video URL from the server response.
    /// Returns nil if extraction fails - caller should fall back to WebView embed.
    static func extractVideoURL(from serverURL: URL) async -> URL? {
        (await resolveStreams(for: serverURL)).first?.url
    }

    static func resolveStreams(for serverURL: URL) async -> [ResolvedStream] {
        // For now, we'll try to detect if the URL is already a direct video URL
        // or if it needs to be loaded as an embed
        
        let urlString = serverURL.absoluteString.lowercased()
        let pathExtension = serverURL.pathExtension.lowercased()

        // Direct video file URLs (mp4, m3u8, etc.). Check the path extension
        // separately so signed URLs with query parameters are recognised too.
        if ["mp4", "m3u8", "m3u", "webm", "mov"].contains(pathExtension) ||
           urlString.contains(".m3u8?") || urlString.contains(".mp4?") {
            return [ResolvedStream(id: serverURL.absoluteString, name: "Direct stream", url: serverURL)]
        }

        // VixSrc serves a short-lived embed token from /api/movie or /api/tv,
        // then publishes the signed HLS master playlist in the embed HTML.
        // Resolve that chain before falling back to the web player.
        if serverURL.host?.lowercased().contains("vixsrc") == true,
           let vixSrcStreams = await extractVixSrcStreams(from: serverURL) {
            return vixSrcStreams
        }

        // Cinezo's embed page loads its playable URLs from the same JSON
        // resolvers used by the web player. Resolve those URLs directly so
        // AVPlayer can provide native captions, scrubbing, PiP, and servers.
        if serverURL.host?.lowercased().contains("cinezo") == true,
           let cinezoStreams = await extractCinezoStreams(from: serverURL),
           !cinezoStreams.isEmpty {
            return cinezoStreams
        }
        
        // Try to fetch the page and look for video sources
        if let url = await extractFromHTML(serverURL) {
            return [ResolvedStream(
                id: url.absoluteString,
                name: "Direct stream",
                url: url,
                requestHeaders: ["User-Agent": userAgent]
            )]
        }
        return []
    }

    private static func extractCinezoStreams(from pageURL: URL) async -> [ResolvedStream]? {
        guard let route = mediaRoute(in: pageURL), route.count >= 2 else { return nil }
        let type = route[0]
        let id = route[1]
        let season = route.count > 2 ? route[2] : nil
        let episode = route.count > 3 ? route[3] : nil
        if type == "tv" && (season == nil || episode == nil) { return nil }

        let sourceDefinitions: [(name: String, base: String, source: String)] = [
            ("Berlin", "https://proxy1.flikhub.net", "berlin"),
            ("Zendaya", "https://proxy3.flikhub.net", "zendaya"),
            ("Sadie", "https://proxy1.flikhub.net", "cinefreak"),
            ("Jennifer", "https://punkflix.net", "jennifer")
        ]

        var resolved: [ResolvedStream] = []
        for source in sourceDefinitions {
            guard let endpoint = cinezoEndpoint(
                base: source.base,
                type: type,
                id: id,
                season: season,
                episode: episode,
                source: source.source
            ) else { continue }

            do {
                var request = URLRequest(url: endpoint)
                request.timeoutInterval = 12
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else { continue }

                for (index, streamURL) in mediaURLs(in: data).enumerated() {
                    let name = resolved.isEmpty && index == 0 ? source.name : "\(source.name) \(index + 1)"
                    if !resolved.contains(where: { $0.url == streamURL }) {
                        resolved.append(ResolvedStream(
                            id: streamURL.absoluteString,
                            name: name,
                            url: streamURL,
                            requestHeaders: ["User-Agent": userAgent]
                        ))
                    }
                }
            } catch {
                continue
            }
        }

        return resolved.isEmpty ? nil : resolved
    }

    private static func cinezoEndpoint(
        base: String,
        type: String,
        id: String,
        season: String?,
        episode: String?,
        source: String
    ) -> URL? {
        if base.contains("punkflix.net") {
            let path = type == "tv"
                ? "/tv/\(id)/\(season ?? "")/\(episode ?? "").json"
                : "/movie/\(id).json"
            return URL(string: base + path)
        }

        var components = URLComponents(string: base + "/" + type)
        components?.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "mode", value: "json"),
            URLQueryItem(name: "sources", value: source),
            URLQueryItem(name: "hevc", value: "1")
        ]
        if type == "tv" {
            components?.queryItems?.append(URLQueryItem(name: "season", value: season))
            components?.queryItems?.append(URLQueryItem(name: "episode", value: episode))
        }
        return components?.url
    }

    private static func mediaURLs(in data: Data) -> [URL] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var values: [String] = []

        func collect(_ value: Any) {
            if let string = value as? String {
                let normalized = string.replacingOccurrences(of: "\\/", with: "/")
                if let url = URL(string: normalized),
                   ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                   (normalized.localizedCaseInsensitiveContains(".m3u8") ||
                    normalized.localizedCaseInsensitiveContains(".mp4") ||
                    normalized.localizedCaseInsensitiveContains("/stream") ||
                    normalized.localizedCaseInsensitiveContains("/file") ||
                    normalized.localizedCaseInsensitiveContains("/remux") ||
                    normalized.localizedCaseInsensitiveContains("/hls")) {
                    values.append(normalized)
                }
            } else if let dictionary = value as? [String: Any] {
                dictionary.values.forEach(collect)
            } else if let array = value as? [Any] {
                array.forEach(collect)
            }
        }

        collect(object)
        var unique: [URL] = []
        for value in values {
            if let url = URL(string: value), !unique.contains(url) {
                unique.append(url)
            }
        }
        return unique
    }

    private static func extractVixSrcStreams(from pageURL: URL) async -> [ResolvedStream]? {
        guard let components = mediaRoute(in: pageURL), components.count >= 2 else { return nil }

        let endpoint: String
        switch components[0].lowercased() {
        case "movie":
            endpoint = "/api/movie/\(components[1])"
        case "tv":
            guard components.count >= 4 else { return nil }
            endpoint = "/api/tv/\(components[1])/\(components[2])/\(components[3])"
        default:
            return nil
        }

        guard let host = pageURL.host else { return nil }
        var apiComponents = URLComponents()
        apiComponents.scheme = pageURL.scheme ?? "https"
        apiComponents.host = host
        apiComponents.path = endpoint

        do {
            var apiRequest = URLRequest(url: apiComponents.url!)
            apiRequest.timeoutInterval = 15
            apiRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            apiRequest.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer")
            let (apiData, _) = try await URLSession.shared.data(for: apiRequest)
            let payload = try JSONDecoder().decode(VixSrcAPIResponse.self, from: apiData)
            guard let embedPath = payload.src,
                  let embedURL = URL(string: embedPath, relativeTo: pageURL)?.absoluteURL
            else { return nil }

            var embedRequest = URLRequest(url: embedURL)
            embedRequest.timeoutInterval = 15
            embedRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            embedRequest.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer")
            let (embedData, _) = try await URLSession.shared.data(for: embedRequest)
            guard let html = String(data: embedData, encoding: .utf8),
                  let playlistURLs = playlistURLs(from: html, embedURL: embedURL)
            else { return nil }

            return playlistURLs
        } catch {
            return nil
        }
    }

    /// Configured embeds commonly prefix their media path with `/embed`.
    /// Normalize both `/movie/id` and `/embed/movie/id` before resolving.
    private static func mediaRoute(in url: URL) -> [String]? {
        let components = url.pathComponents.filter { $0 != "/" }
        guard let index = components.firstIndex(where: {
            let value = $0.lowercased()
            return value == "movie" || value == "tv"
        }) else { return nil }
        return Array(components[index...]).map { $0.removingPercentEncoding ?? $0 }
    }

    private static func playlistURLs(from html: String, embedURL: URL) -> [ResolvedStream]? {
        guard let rawURL = firstCapture(
            pattern: "(?:window\\.)?masterPlaylist\\s*=\\s*\\{[\\s\\S]*?url\\s*:\\s*['\\\"]([^'\\\"]+)['\\\"]",
            in: html
        ), let baseURL = URL(string: rawURL, relativeTo: embedURL)?.absoluteURL,
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true)
        else { return nil }

        let paramsBlock = firstCapture(
            pattern: "masterPlaylist\\s*=\\s*\\{[\\s\\S]*?params\\s*:\\s*\\{([\\s\\S]*?)\\}[^}]*url",
            in: html
        ) ?? ""
        let parameterPattern = "['\\\"]([^'\\\"]+)['\\\"]\\s*:\\s*['\\\"]([^'\\\"]*)['\\\"]"
        if let regex = try? NSRegularExpression(pattern: parameterPattern),
           let range = Range(NSRange(location: 0, length: paramsBlock.utf16.count), in: paramsBlock) {
            for match in regex.matches(in: paramsBlock, range: NSRange(range, in: paramsBlock)) {
                guard let keyRange = Range(match.range(at: 1), in: paramsBlock),
                      let valueRange = Range(match.range(at: 2), in: paramsBlock) else { continue }
                let key = String(paramsBlock[keyRange])
                let value = String(paramsBlock[valueRange])
                if !value.isEmpty {
                    components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: key, value: value)]
                }
            }
        }

        let embedQuery = URLComponents(url: embedURL, resolvingAgainstBaseURL: true)?.queryItems ?? []
        if let language = embedQuery.first(where: { $0.name == "lang" })?.value {
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "lang", value: language)]
        }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "h", value: "1")]

        var streams: [ResolvedStream] = []
        let streamPattern = "\\{\\s*['\\\"]name['\\\"]\\s*:\\s*['\\\"]([^'\\\"]+)['\\\"][\\s\\S]*?['\\\"]url['\\\"]\\s*:\\s*['\\\"]([^'\\\"]+)['\\\"]"
        if let regex = try? NSRegularExpression(pattern: streamPattern, options: [.caseInsensitive]) {
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let nameRange = Range(match.range(at: 1), in: html),
                      let urlRange = Range(match.range(at: 2), in: html) else { continue }
                let name = String(html[nameRange])
                let rawStreamURL = String(html[urlRange]).replacingOccurrences(of: "\\/", with: "/")
                guard let streamURL = URL(string: rawStreamURL, relativeTo: embedURL)?.absoluteURL,
                      var streamComponents = URLComponents(url: streamURL, resolvingAgainstBaseURL: true) else { continue }
                // Preserve the sub-server's own selector (for example
                // `ub=1` or `ab=1`) and append the shared signed token.
                streamComponents.queryItems = (streamComponents.queryItems ?? []) + (components.queryItems ?? [])
                if let url = streamComponents.url {
                    streams.append(ResolvedStream(
                        id: name,
                        name: name,
                        url: url,
                        requestHeaders: ["User-Agent": userAgent]
                    ))
                }
            }
        }

        if streams.isEmpty, let url = components.url {
            streams.append(ResolvedStream(
                id: "master",
                name: "Auto",
                url: url,
                requestHeaders: ["User-Agent": userAgent]
            ))
        }
        return streams
    }

    private static func firstCapture(pattern: String, in string: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: string) else { return nil }
        return String(string[range])
    }

    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1"

    private struct VixSrcAPIResponse: Decodable {
        let src: String?
    }
    
    private static func extractFromHTML(_ url: URL) async -> URL? {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            
            // Look for common video URL patterns in the HTML
            let patterns = [
                // M3U8 playlist URLs
                "https?://[^\"'\\s]+(?:\\.m3u8|\\.mp4)[^\"'\\s]*",
                // MP4 URLs
                "https?://[^\"'\\s]+\\.mp4[^\"'\\s]*",
                // Common video source patterns
                "\"(https?://[^\"]+/(?:playlist|manifest|master)\\.m3u8[^\"]*)\"",
                "src=\"(https?://[^\"]+\\.mp4[^\"]*)\"",
            ]
            
            for pattern in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                   let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) {
                    
                    var urlString: String?
                    if match.numberOfRanges > 1 {
                        // Extract from capture group
                        if let range = Range(match.range(at: 1), in: html) {
                            urlString = String(html[range])
                        }
                    } else {
                        // Extract full match
                        if let range = Range(match.range, in: html) {
                            urlString = String(html[range])
                        }
                    }
                    
                    if let rawURL = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
                       let videoURL = URL(string: rawURL
                        .replacingOccurrences(of: "\\/", with: "/")
                        .replacingOccurrences(of: "&amp;", with: "&")) {
                        // Validate it's a real video URL
                        if await validateVideoURL(videoURL) {
                            return videoURL
                        }
                    }
                }
            }
            
            return nil
        } catch {
            print("Failed to extract video URL: \(error)")
            return nil
        }
    }
    
    private static func validateVideoURL(_ url: URL) async -> Bool {
        // Quick HEAD request to verify the URL is accessible
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        request.timeoutInterval = 5
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return (200...299).contains(httpResponse.statusCode)
            }
            return false
        } catch {
            return false
        }
    }
}

/// A WebVTT subtitle file that has to be fetched with a specific Referer.
struct ExternalSubtitle: Hashable, Sendable {
    let label: String
    let url: URL
    let referer: String
}

/// Determines whether to use native player or WebView embed
enum StreamPlaybackMode {
    case native(sources: [StreamURLExtractor.ResolvedStream])
    case embed(pageURL: URL)
}

extension StreamURLExtractor {
    /// Determines the best playback mode for a given server URL
    static func determinePlaybackMode(for url: URL) async -> StreamPlaybackMode {
        let streams = await resolveStreams(for: url)
        if !streams.isEmpty {
            return .native(sources: streams)
        } else {
            return .embed(pageURL: url)
        }
    }
}
