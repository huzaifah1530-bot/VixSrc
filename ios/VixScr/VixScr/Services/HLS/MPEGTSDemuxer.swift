import Foundation

/// One PES packet: a video access unit or a run of audio frames.
struct ElementaryPacket: Sendable {
    /// Presentation time in 90 kHz ticks (33-bit).
    let pts: UInt64?
    let payload: Data
}

/// The audio and video carried by one MPEG-TS segment.
struct TransportStreams: Sendable {
    enum VideoCodec: Sendable { case h264, hevc }
    enum AudioCodec: Sendable { case aacADTS }

    var videoCodec: VideoCodec?
    var video: [ElementaryPacket] = []
    var audioCodec: AudioCodec?
    var audio: [ElementaryPacket] = []
    /// Stream types present that Vela can't decode (e.g. 0x81 AC-3).
    var unsupportedTypes: [UInt8] = []

    var firstVideoPTS: UInt64? { video.lazy.compactMap(\.pts).first }
    var firstAudioPTS: UInt64? { audio.lazy.compactMap(\.pts).first }
}

/// Splits an MPEG-TS segment (188-byte packets) into its audio and video:
/// PAT → PMT → each elementary stream's PES packets with their PTS. HLS
/// segments carry one program, which is all this reads.
enum MPEGTSDemuxer {
    static let packetSize = 188

    /// True when the data starts like a transport stream.
    static func looksLikeTransportStream(_ data: Data) -> Bool {
        data.count >= packetSize * 2 && data[data.startIndex] == 0x47 && data[data.startIndex + packetSize] == 0x47
    }

    static func demux(_ data: Data) -> TransportStreams? {
        guard looksLikeTransportStream(data) else { return nil }
        let bytes = [UInt8](data)
        var pmtPID: Int?
        var streamTypes: [Int: UInt8] = [:]
        var assembling: [Int: [UInt8]] = [:]
        var finished: [Int: [[UInt8]]] = [:]

        var offset = 0
        while offset + packetSize <= bytes.count {
            defer { offset += packetSize }
            guard bytes[offset] == 0x47 else {
                // Resync on the next sync byte.
                if let next = bytes[(offset + 1)...].firstIndex(of: 0x47) { offset = next - packetSize }
                continue
            }
            let unitStart = bytes[offset + 1] & 0x40 != 0
            let pid = Int(bytes[offset + 1] & 0x1f) << 8 | Int(bytes[offset + 2])
            let adaptation = (bytes[offset + 3] >> 4) & 0x3
            var p = offset + 4
            if adaptation == 0 || adaptation == 2 { continue }
            if adaptation == 3 { p += 1 + Int(bytes[offset + 4]) }
            guard p < offset + packetSize else { continue }

            if pid == 0 {
                guard unitStart else { continue }
                p += 1 + Int(bytes[p])
                // First program entry: program number (2), PMT PID (2).
                guard p + 12 <= offset + packetSize else { continue }
                pmtPID = Int(bytes[p + 10] & 0x1f) << 8 | Int(bytes[p + 11])
                continue
            }
            if pid == pmtPID {
                guard unitStart else { continue }
                p += 1 + Int(bytes[p])
                guard p + 12 <= offset + packetSize else { continue }
                let sectionLength = Int(bytes[p + 1] & 0x0f) << 8 | Int(bytes[p + 2])
                let programInfo = Int(bytes[p + 10] & 0x0f) << 8 | Int(bytes[p + 11])
                var q = p + 12 + programInfo
                let end = min(p + 3 + sectionLength - 4, offset + packetSize)
                while q + 5 <= end {
                    let type = bytes[q]
                    let elementary = Int(bytes[q + 1] & 0x1f) << 8 | Int(bytes[q + 2])
                    streamTypes[elementary] = type
                    q += 5 + (Int(bytes[q + 3] & 0x0f) << 8 | Int(bytes[q + 4]))
                }
                continue
            }
            guard streamTypes[pid] != nil else { continue }
            if unitStart {
                if let done = assembling[pid], !done.isEmpty { finished[pid, default: []].append(done) }
                assembling[pid] = []
            }
            guard assembling[pid] != nil else { continue }
            assembling[pid]?.append(contentsOf: bytes[p..<(offset + packetSize)])
        }
        for (pid, rest) in assembling where !rest.isEmpty { finished[pid, default: []].append(rest) }

        var result = TransportStreams()
        for (pid, type) in streamTypes.sorted(by: { $0.key < $1.key }) {
            let packets = (finished[pid] ?? []).compactMap(parsePES)
            switch type {
            case 0x1b where result.videoCodec == nil:
                result.videoCodec = .h264
                result.video = packets
            case 0x24 where result.videoCodec == nil:
                result.videoCodec = .hevc
                result.video = packets
            case 0x0f where result.audioCodec == nil:
                result.audioCodec = .aacADTS
                result.audio = packets
            default:
                result.unsupportedTypes.append(type)
            }
        }
        return result
    }

    private static func parsePES(_ b: [UInt8]) -> ElementaryPacket? {
        guard b.count >= 9, b[0] == 0, b[1] == 0, b[2] == 1 else { return nil }
        let headerLength = Int(b[8])
        guard 9 + headerLength <= b.count else { return nil }
        var pts: UInt64?
        if b[7] & 0x80 != 0, b.count >= 14 {
            pts = UInt64(b[9] & 0x0e) << 29 | UInt64(b[10]) << 22 | UInt64(b[11] & 0xfe) << 14
                | UInt64(b[12]) << 7 | UInt64(b[13] >> 1)
        }
        return ElementaryPacket(pts: pts, payload: Data(b[(9 + headerLength)...]))
    }

    /// Seconds from `base` to `pts`, allowing for the 33-bit wrap.
    static func seconds(_ pts: UInt64, since base: UInt64) -> Double {
        let wrap: UInt64 = 1 << 33
        var delta = Int64(bitPattern: (pts &- base) & (wrap - 1))
        if delta > Int64(wrap / 2) { delta -= Int64(wrap) }
        return Double(delta) / 90_000
    }
}
