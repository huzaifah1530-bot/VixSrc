import Foundation

/// One timed caption from a WebVTT file.
struct SubtitleCue: Sendable {
    let start: Double
    let end: Double
    let text: String
}

/// Minimal WebVTT parser for side-loaded anime subtitles. Handles both
/// `HH:MM:SS.mmm` and the two-part `MM:SS.mmm` timestamps some hosts emit,
/// and strips inline styling tags (`<i>`, `<c.x>`, karaoke timestamps).
enum WebVTT {
    static func parse(_ text: String) -> [SubtitleCue] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var cues: [SubtitleCue] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard line.contains("-->") else { index += 1; continue }
            let parts = line.components(separatedBy: "-->")
            let endField = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? "" : ""
            guard let start = seconds(parts[0].trimmingCharacters(in: .whitespaces)), let end = seconds(endField) else {
                index += 1
                continue
            }
            index += 1
            var body: [String] = []
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                body.append(lines[index])
                index += 1
            }
            let cleaned = body.joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: cleaned)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    private static func seconds(_ stamp: String) -> Double? {
        let parts = stamp.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }
}
