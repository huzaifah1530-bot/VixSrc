import Foundation

/// The parts of an HLS master playlist Vela reads itself.
struct HLSMasterPlaylist: Sendable {
    struct Variant: Sendable {
        let url: URL
        let bandwidth: Int
        let height: Int?
        let codecs: String?
        let audioGroup: String?
    }

    struct Rendition: Sendable {
        let groupID: String
        let name: String
        let language: String?
        let isDefault: Bool
        /// nil: the audio is inside the variant's own segments.
        let url: URL?
    }

    var variants: [Variant]
    var audio: [Rendition]
}

/// A media playlist: the segment files, in order, with their timeline.
struct HLSMediaPlaylist: Sendable {
    struct Key: Sendable, Hashable {
        let method: String
        let url: URL?
        let iv: Data?
    }

    struct Segment: Sendable {
        let index: Int
        let url: URL
        /// Playlist time the segment starts at, seconds.
        let start: Double
        let duration: Double
        let sequence: Int
        let key: Key?
        /// (length, offset) for `#EXT-X-BYTERANGE`.
        let byteRange: (length: Int, offset: Int)?
    }

    var segments: [Segment]
    /// `#EXT-X-MAP`: fragmented MP4 segments, which Vela doesn't unpack.
    var initSection: URL?

    var duration: Double { segments.last.map { $0.start + $0.duration } ?? 0 }

    /// Index of the segment playing at `time`.
    func index(at time: Double) -> Int? {
        guard !segments.isEmpty else { return nil }
        if time <= 0 { return 0 }
        var low = 0, high = segments.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if segments[mid].start <= time { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func segments(from start: Double, to end: Double) -> [Segment] {
        guard let first = index(at: start) else { return [] }
        return Array(segments[first...].prefix { $0.start < end })
    }
}

enum HLSParser {
    enum Playlist: Sendable {
        case master(HLSMasterPlaylist)
        case media(HLSMediaPlaylist)
    }

    static func parse(_ text: String, base: URL) -> Playlist? {
        let lines = text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.contains(where: { $0.hasPrefix("#EXTM3U") }) else { return nil }
        if lines.contains(where: { $0.hasPrefix("#EXTINF") }) {
            return .media(media(lines, base: base))
        }
        return .master(master(lines, base: base))
    }

    private static func master(_ lines: [String], base: URL) -> HLSMasterPlaylist {
        var variants: [HLSMasterPlaylist.Variant] = []
        var audio: [HLSMasterPlaylist.Rendition] = []
        var pending: [String: String]?
        for line in lines {
            if line.hasPrefix("#EXT-X-MEDIA:") {
                let a = attributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                guard a["TYPE"] == "AUDIO" else { continue }
                audio.append(.init(groupID: a["GROUP-ID"] ?? "", name: a["NAME"] ?? "",
                                   language: a["LANGUAGE"], isDefault: a["DEFAULT"] == "YES",
                                   url: a["URI"].flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }))
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            } else if let a = pending, !line.isEmpty, !line.hasPrefix("#") {
                pending = nil
                guard let url = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
                let height = a["RESOLUTION"]?.split(separator: "x").last.flatMap { Int($0) }
                variants.append(.init(url: url, bandwidth: Int(a["BANDWIDTH"] ?? "") ?? 0, height: height,
                                      codecs: a["CODECS"], audioGroup: a["AUDIO"]))
            }
        }
        return HLSMasterPlaylist(variants: variants, audio: audio)
    }

    private static func media(_ lines: [String], base: URL) -> HLSMediaPlaylist {
        var segments: [HLSMediaPlaylist.Segment] = []
        var sequence = 0
        var key: HLSMediaPlaylist.Key?
        var duration: Double?
        var range: (Int, Int?)?
        var lastRangeEnd = 0
        var time = 0.0
        var initSection: URL?
        for line in lines {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                sequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let a = attributes(String(line.dropFirst("#EXT-X-KEY:".count)))
                let method = a["METHOD"] ?? "NONE"
                key = method == "NONE" ? nil : .init(method: method,
                                                    url: a["URI"].flatMap { URL(string: $0, relativeTo: base)?.absoluteURL },
                                                    iv: a["IV"].flatMap(hexData))
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let a = attributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                initSection = a["URI"].flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
            } else if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",").first.map(String.init) ?? ""
                duration = Double(value)
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                let parts = line.dropFirst("#EXT-X-BYTERANGE:".count).split(separator: "@")
                if let length = parts.first.flatMap({ Int($0) }) {
                    range = (length, parts.count > 1 ? Int(parts[1]) : nil)
                }
            } else if !line.isEmpty, !line.hasPrefix("#"), let length = duration {
                if let url = URL(string: line, relativeTo: base)?.absoluteURL {
                    var byteRange: (length: Int, offset: Int)?
                    if let range {
                        let offset = range.1 ?? lastRangeEnd
                        byteRange = (range.0, offset)
                        lastRangeEnd = offset + range.0
                    }
                    segments.append(.init(index: segments.count, url: url, start: time, duration: length,
                                          sequence: sequence, key: key, byteRange: byteRange))
                }
                time += length
                sequence += 1
                duration = nil
                range = nil
            }
        }
        return HLSMediaPlaylist(segments: segments, initSection: initSection)
    }

    /// `KEY=VALUE,KEY="quoted, value"` attribute lists.
    static func attributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var readingKey = true
        var quoted = false
        func flush() {
            let k = key.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { result[k] = value }
            key = ""
            value = ""
            readingKey = true
        }
        for ch in text {
            if readingKey {
                if ch == "=" { readingKey = false } else if ch != "," { key.append(ch) }
            } else if ch == "\"" {
                quoted.toggle()
            } else if ch == ",", !quoted {
                flush()
            } else {
                value.append(ch)
            }
        }
        flush()
        return result
    }

    private static func hexData(_ text: String) -> Data? {
        var hex = text.lowercased()
        if hex.hasPrefix("0x") { hex.removeFirst(2) }
        hex = String(repeating: "0", count: max(0, 32 - hex.count)) + hex
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data.count == 16 ? data : nil
    }
}
