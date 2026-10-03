import Foundation

/// Extracts direct video URLs from streaming server responses.
/// For servers that return direct video URLs or have extractable patterns.
struct StreamURLExtractor {

    struct ResolvedStream: Identifiable, Hashable {
        let id: String
        let name: String
        let url: URL
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
        
        // Try to fetch the page and look for video sources
        if let url = await extractFromHTML(serverURL) {
            return [ResolvedStream(id: url.absoluteString, name: "Direct stream", url: url)]
        }
        return []
    }

    private static func extractVixSrcStreams(from pageURL: URL) async -> [ResolvedStream]? {
        let components = pageURL.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else { return nil }

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
                    streams.append(ResolvedStream(id: name, name: name, url: url))
                }
            }
        }

        if streams.isEmpty, let url = components.url {
            streams.append(ResolvedStream(id: "master", name: "Auto", url: url))
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

    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1"

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
