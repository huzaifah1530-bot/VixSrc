import AVFoundation
import CommonCrypto
import CoreMedia
import Foundation
import VideoToolbox

/// Decoded mono audio starting at `start` on the player's timeline.
struct AudioChunk: Sendable {
    let start: Double
    let rate: Double
    let samples: [Float]
    /// Playlist time the downloaded segments reach; where the next request
    /// should begin so nothing is decoded twice.
    var playlistEnd: Double = 0
    var duration: Double { Double(samples.count) / rate }
    var end: Double { start + duration }
}

/// Reads an HLS stream's segment files directly, without AVPlayer: picks
/// the playlists, downloads only the segments for a time range, decrypts
/// AES-128, unpacks MPEG-TS and decodes the sound (AAC) and picture
/// (H.264 / HEVC) on the device.
///
/// iOS's own decoded-audio output (iOS 27) delivers nothing for the hosts
/// Vela uses, and there's no way to pull frames out of an HLS item, so this
/// is how captions get sound and recorded segments get fingerprinted
/// without making anyone watch them. Checked against VixSrc (encrypted TS,
/// separate audio tracks) and AnimeKai's hosts (plain TS, audio muxed in).
actor HLSStreamReader {
    enum Failure: LocalizedError {
        case playlist, unsupported(String), download(String)

        var errorDescription: String? {
            switch self {
            case .playlist: "The stream's playlist couldn't be read."
            case .unsupported(let what): "This stream uses \(what), which Vela can't read directly."
            case .download(let what): "Couldn't download the stream (\(what))."
            }
        }
    }

    private let url: URL
    private let headers: [String: String]
    private let preferredAudioLanguage: String?
    private let session: URLSession

    private var audioPlaylist: HLSMediaPlaylist?
    private var videoPlaylist: HLSMediaPlaylist?
    private var keys: [URL: Data] = [:]
    /// Seconds to add to a PTS (since `ptsBase`) to land on the playlist
    /// timeline, per playlist (audio, video).
    private var audioTimeline: (base: UInt64, start: Double)?
    private var videoTimeline: (base: UInt64, start: Double)?

    init(url: URL, requestHeaders: [String: String], cookies: [HTTPCookie] = [], audioLanguage: String? = nil) {
        self.url = url
        var headers = requestHeaders
        if headers["User-Agent"] == nil { headers["User-Agent"] = StreamURLExtractor.userAgent }
        for (key, value) in HTTPCookie.requestHeaderFields(with: cookies) { headers[key] = value }
        self.headers = headers
        self.preferredAudioLanguage = audioLanguage.map(MediaLanguage.normalize)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    var duration: Double { audioPlaylist?.duration ?? videoPlaylist?.duration ?? 0 }

    /// Start of the audio segment holding `time`, so reads line up with
    /// segment boundaries.
    func audioSegmentStart(at time: Double) async throws -> Double {
        try await prepare()
        guard let playlist = audioPlaylist, let index = playlist.index(at: time) else { return max(0, time) }
        return playlist.segments[index].start
    }

    // MARK: Playlists

    /// Loads the playlists once. Audio comes from a separate audio track
    /// when the stream has one (in the preferred language), otherwise from
    /// the lowest-bandwidth variant, whose segments carry it muxed in.
    func prepare() async throws {
        guard audioPlaylist == nil || videoPlaylist == nil else { return }
        guard let top = HLSParser.parse(try await text(url), base: url) else { throw Failure.playlist }
        switch top {
        case .media(let media):
            audioPlaylist = media
            videoPlaylist = media
        case .master(let master):
            // Fingerprints don't depend on resolution: the smallest video.
            let variants = master.variants.sorted { $0.bandwidth < $1.bandwidth }
            guard let variant = variants.first(where: { $0.codecs.map(Self.isSupportedVideo) ?? true }) ?? variants.first else {
                throw Failure.playlist
            }
            videoPlaylist = try await mediaPlaylist(variant.url)
            let group = master.audio.filter { $0.groupID == variant.audioGroup && $0.url != nil }
            let rendition = group.first { r in preferredAudioLanguage.map { MediaLanguage.normalize(r.language ?? "") == $0 } ?? false }
                ?? group.first(where: \.isDefault) ?? group.first
            if let renditionURL = rendition?.url {
                audioPlaylist = try await mediaPlaylist(renditionURL)
            } else {
                audioPlaylist = videoPlaylist
            }
        }
        if videoPlaylist?.initSection != nil || audioPlaylist?.initSection != nil {
            throw Failure.unsupported("fragmented MP4 segments")
        }
    }

    private static func isSupportedVideo(_ codecs: String) -> Bool {
        let lower = codecs.lowercased()
        return lower.contains("avc1") || lower.contains("hvc1") || lower.contains("hev1") || !lower.contains("v")
    }

    private func mediaPlaylist(_ url: URL) async throws -> HLSMediaPlaylist {
        guard case .media(let media)? = HLSParser.parse(try await text(url), base: url), !media.segments.isEmpty else {
            throw Failure.playlist
        }
        return media
    }

    // MARK: Audio

    /// Decoded audio covering `start...end`, as one chunk per unbroken run.
    func audio(from start: Double, to end: Double) async throws -> [AudioChunk] {
        try await prepare()
        guard let playlist = audioPlaylist else { throw Failure.playlist }
        let segments = playlist.segments(from: max(0, start), to: end)
        guard !segments.isEmpty else { return [] }
        let timeline = try await anchor(playlist, audio: true)
        let datas = try await download(segments)
        var adts = Data()
        var firstPTS: UInt64?
        for data in datas {
            guard let streams = MPEGTSDemuxer.demux(data) else { throw Failure.unsupported("an unknown segment format") }
            guard streams.audioCodec == .aacADTS else {
                throw Failure.unsupported(streams.audio.isEmpty ? "no AAC audio" : "an audio codec other than AAC")
            }
            if firstPTS == nil { firstPTS = streams.firstAudioPTS }
            for packet in streams.audio { adts.append(packet.payload) }
        }
        guard let firstPTS, !adts.isEmpty else { return [] }
        let chunkStart = timeline.start + MPEGTSDemuxer.seconds(firstPTS, since: timeline.base)
        guard let decoded = try Self.decodeADTS(adts) else { return [] }
        let reach = segments.last.map { $0.start + $0.duration } ?? end
        return [AudioChunk(start: chunkStart, rate: decoded.rate, samples: decoded.samples, playlistEnd: reach)]
    }

    /// AAC in ADTS framing → mono floats. Core Audio reads ADTS files
    /// directly, which also handles every AAC profile the hosts use.
    private static func decodeADTS(_ adts: Data) throws -> (samples: [Float], rate: Double)? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vela-\(UUID().uuidString).aac")
        try adts.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let audio = try AVAudioFile(forReading: file, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = audio.processingFormat
        let frames = AVAudioFrameCount(audio.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        try audio.read(into: buffer)
        guard let channels = buffer.floatChannelData else { return nil }
        let count = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: count)
        for c in 0..<channelCount {
            let channel = channels[c]
            for i in 0..<count { mono[i] += channel[i] }
        }
        if channelCount > 1 {
            let scale = 1 / Float(channelCount)
            for i in 0..<count { mono[i] *= scale }
        }
        return (mono, format.sampleRate)
    }

    // MARK: Picture

    /// One `VisualSample` per `interval` seconds of `start...end`.
    func visualSamples(from start: Double, to end: Double, interval: Double = 0.25,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> [VisualSample] {
        try await prepare()
        guard let playlist = videoPlaylist else { throw Failure.playlist }
        let segments = playlist.segments(from: max(0, start), to: end)
        guard !segments.isEmpty else { return [] }
        let timeline = try await anchor(playlist, audio: false)
        let decoder = VideoFrameDecoder(interval: interval)
        var done = 0
        // A few at a time: decoding keeps up easily with the network.
        for batch in stride(from: 0, to: segments.count, by: 4).map({ Array(segments[$0..<min($0 + 4, segments.count)]) }) {
            let datas = try await download(batch)
            for data in datas {
                guard let streams = MPEGTSDemuxer.demux(data) else { throw Failure.unsupported("an unknown segment format") }
                guard let codec = streams.videoCodec else { throw Failure.unsupported("no H.264 or HEVC video") }
                decoder.decode(streams.video, codec: codec) { pts in
                    timeline.start + MPEGTSDemuxer.seconds(pts, since: timeline.base)
                }
                done += 1
                progress?(Double(done) / Double(segments.count))
            }
        }
        decoder.finish()
        return decoder.samples.filter { $0.time >= start - interval && $0.time <= end + interval }.sorted { $0.time < $1.time }
    }

    /// Where the stream's clock starts: the first timestamp of the first
    /// segment is time 0, as the player counts it. Read once per playlist.
    private func anchor(_ playlist: HLSMediaPlaylist, audio: Bool) async throws -> (base: UInt64, start: Double) {
        if audio, let audioTimeline { return audioTimeline }
        if !audio, let videoTimeline { return videoTimeline }
        guard let first = playlist.segments.first, let data = try await download([first]).first,
              let streams = MPEGTSDemuxer.demux(data),
              let pts = audio ? streams.firstAudioPTS : streams.firstVideoPTS else {
            throw Failure.unsupported(audio ? "no readable audio" : "no readable video")
        }
        let timeline = (base: pts, start: first.start)
        if audio { audioTimeline = timeline } else { videoTimeline = timeline }
        // Same files for both (sound muxed into the video): one clock.
        if audioPlaylist?.segments.first?.url == videoPlaylist?.segments.first?.url {
            audioTimeline = audioTimeline ?? timeline
            videoTimeline = videoTimeline ?? timeline
        }
        return timeline
    }

    // MARK: Downloads

    private func text(_ url: URL) async throws -> String {
        String(decoding: try await bytes(url, range: nil), as: UTF8.self)
    }

    private func bytes(_ url: URL, range: (length: Int, offset: Int)?) async throws -> Data {
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let range { request.setValue("bytes=\(range.offset)-\(range.offset + range.length - 1)", forHTTPHeaderField: "Range") }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw Failure.download("HTTP \(http.statusCode)")
        }
        return data
    }

    /// Downloads (in parallel) and decrypts segments, in playlist order.
    private func download(_ segments: [HLSMediaPlaylist.Segment]) async throws -> [Data] {
        for key in Set(segments.compactMap(\.key)) where key.method == "AES-128" {
            if let keyURL = key.url, keys[keyURL] == nil { keys[keyURL] = try await bytes(keyURL, range: nil) }
        }
        if let other = segments.compactMap(\.key).first(where: { $0.method != "AES-128" }) {
            throw Failure.unsupported("\(other.method) encryption")
        }
        let headers = headers
        let session = session
        let keys = keys
        return try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for (position, segment) in segments.enumerated() {
                group.addTask {
                    var request = URLRequest(url: segment.url)
                    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
                    if let range = segment.byteRange {
                        request.setValue("bytes=\(range.offset)-\(range.offset + range.length - 1)", forHTTPHeaderField: "Range")
                    }
                    let (data, response) = try await session.data(for: request)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        throw Failure.download("HTTP \(http.statusCode)")
                    }
                    guard let key = segment.key else { return (position, data) }
                    guard let keyURL = key.url, let keyData = keys[keyURL] else { throw Failure.download("missing key") }
                    let iv = key.iv ?? Self.sequenceIV(segment.sequence)
                    guard let plain = Self.decryptAES128(data, key: keyData, iv: iv) else { throw Failure.download("decryption failed") }
                    return (position, plain)
                }
            }
            var out = [Data](repeating: Data(), count: segments.count)
            for try await (position, data) in group { out[position] = data }
            return out
        }
    }

    /// Without an IV attribute, HLS uses the media sequence number.
    private static func sequenceIV(_ sequence: Int) -> Data {
        var iv = Data(repeating: 0, count: 16)
        let value = UInt64(max(0, sequence))
        for i in 0..<8 { iv[15 - i] = UInt8((value >> (8 * UInt64(i))) & 0xff) }
        return iv
    }

    private static func decryptAES128(_ data: Data, key: Data, iv: Data) -> Data? {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else { return nil }
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var written = 0
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, kCCKeySizeAES128, ivBytes.baseAddress,
                                inBytes.baseAddress, data.count, outBytes.baseAddress, outCount, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.removeSubrange(written...)
        return out
    }
}

// MARK: - Video decoding

/// Decodes H.264 / HEVC access units with VideoToolbox (hardware) and keeps
/// one fingerprint per interval. Every frame is decoded, since later frames
/// depend on earlier ones, but only the first in each interval is hashed.
private final class VideoFrameDecoder {
    private let interval: Double
    private let collector = FrameCollector()
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [[UInt8]] = []

    var samples: [VisualSample] { collector.samples }

    init(interval: Double) { self.interval = interval }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    func decode(_ packets: [ElementaryPacket], codec: TransportStreams.VideoCodec, time: (UInt64) -> Double) {
        for packet in packets {
            guard let pts = packet.pts else { continue }
            let units = Self.nalUnits(in: [UInt8](packet.payload))
            var sets: [[UInt8]] = []
            var frame: [[UInt8]] = []
            for unit in units where !unit.isEmpty {
                switch codec {
                case .h264:
                    let type = unit[0] & 0x1f
                    if type == 7 || type == 8 { sets.append(unit) } else if type != 9 { frame.append(unit) }
                case .hevc:
                    let type = (unit[0] >> 1) & 0x3f
                    if (32...34).contains(type) { sets.append(unit) } else if type != 35 { frame.append(unit) }
                }
            }
            if !sets.isEmpty, sets != parameterSets, makeSession(sets, codec: codec) { parameterSets = sets }
            guard let session, let format, !frame.isEmpty,
                  let sample = Self.sampleBuffer(frame, format: format, pts: pts) else { continue }
            let seconds = time(pts)
            let collector = collector
            let interval = interval
            VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                guard status == noErr, let image else { return }
                collector.offer(image, time: seconds, interval: interval)
            }
        }
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
    }

    func finish() {
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
    }

    private func makeSession(_ sets: [[UInt8]], codec: TransportStreams.VideoCodec) -> Bool {
        // H.264 needs SPS + PPS; HEVC needs VPS + SPS + PPS, in that order.
        let ordered: [[UInt8]]
        switch codec {
        case .h264:
            guard let sps = sets.first(where: { $0[0] & 0x1f == 7 }), let pps = sets.first(where: { $0[0] & 0x1f == 8 }) else { return false }
            ordered = [sps, pps]
        case .hevc:
            let find = { (type: UInt8) in sets.first { ($0[0] >> 1) & 0x3f == type } }
            guard let vps = find(32), let sps = find(33), let pps = find(34) else { return false }
            ordered = [vps, sps, pps]
        }
        let pointers = ordered.map { set -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            pointer.initialize(from: set, count: set.count)
            return pointer
        }
        defer { pointers.forEach { $0.deallocate() } }
        let constPointers = pointers.map { UnsafePointer($0) }
        let sizes = ordered.map(\.count)
        var description: CMFormatDescription?
        let status: OSStatus
        switch codec {
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: ordered.count,
                parameterSetPointers: constPointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        case .hevc:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: ordered.count,
                parameterSetPointers: constPointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
        }
        guard status == noErr, let description else { return false }
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        var created: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description,
                                           decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
                                           outputCallback: nil, decompressionSessionOut: &created) == noErr,
              let created else { return false }
        session = created
        format = description
        return true
    }

    /// Annex B (start-code separated) NAL units.
    private static func nalUnits(in bytes: [UInt8]) -> [[UInt8]] {
        var units: [[UInt8]] = []
        var start: Int?
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if let s = start {
                    var end = i
                    if end > s, bytes[end - 1] == 0 { end -= 1 }
                    units.append(Array(bytes[s..<end]))
                }
                i += 3
                start = i
                continue
            }
            i += 1
        }
        if let s = start, s < bytes.count { units.append(Array(bytes[s...])) }
        return units
    }

    /// Length-prefixed (AVCC / HVCC) sample from NAL units.
    private static func sampleBuffer(_ units: [[UInt8]], format: CMVideoFormatDescription, pts: UInt64) -> CMSampleBuffer? {
        var payload: [UInt8] = []
        payload.reserveCapacity(units.reduce(0) { $0 + $1.count + 4 })
        for unit in units {
            let length = UInt32(unit.count)
            payload.append(contentsOf: [UInt8(length >> 24), UInt8((length >> 16) & 0xff), UInt8((length >> 8) & 0xff), UInt8(length & 0xff)])
            payload.append(contentsOf: unit)
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: payload.count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { return nil }
        let copied = payload.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: CMTimeValue(pts), timescale: 90_000),
                                        decodeTimeStamp: .invalid)
        var size = payload.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}

/// Collects hashed frames from VideoToolbox's callback, which may run on
/// its own thread.
private final class FrameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buckets = Set<Int>()
    private var stored: [VisualSample] = []

    var samples: [VisualSample] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func offer(_ image: CVImageBuffer, time: Double, interval: Double) {
        let bucket = Int((time / interval).rounded(.down))
        lock.lock()
        let fresh = buckets.insert(bucket).inserted
        lock.unlock()
        guard fresh, let sample = FrameHasher.sample(image, time: time) else { return }
        lock.lock()
        stored.append(sample)
        lock.unlock()
    }
}
