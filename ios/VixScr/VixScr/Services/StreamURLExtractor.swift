import Foundation

/// Extracts direct video URLs from streaming server responses.
/// For servers that return direct video URLs or have extractable patterns.
struct StreamURLExtractor {
    
    /// Attempts to extract a direct video URL from the server response.
    /// Returns nil if extraction fails - caller should fall back to WebView embed.
    static func extractVideoURL(from serverURL: URL) async -> URL? {
        // For now, we'll try to detect if the URL is already a direct video URL
        // or if it needs to be loaded as an embed
        
        let urlString = serverURL.absoluteString.lowercased()
        let pathExtension = serverURL.pathExtension.lowercased()

        // Direct video file URLs (mp4, m3u8, etc.). Check the path extension
        // separately so signed URLs with query parameters are recognised too.
        if ["mp4", "m3u8", "m3u", "webm", "mov"].contains(pathExtension) ||
           urlString.contains(".m3u8?") || urlString.contains(".mp4?") {
            return serverURL
        }
        
        // Try to fetch the page and look for video sources
        return await extractFromHTML(serverURL)
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
    case native(videoURL: URL)
    case embed(pageURL: URL)
}

extension StreamURLExtractor {
    /// Determines the best playback mode for a given server URL
    static func determinePlaybackMode(for url: URL) async -> StreamPlaybackMode {
        if let videoURL = await extractVideoURL(from: url) {
            return .native(videoURL: videoURL)
        } else {
            return .embed(pageURL: url)
        }
    }
}
