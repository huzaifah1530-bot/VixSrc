import Foundation

/// One analysed video frame: a 64-bit difference hash of its brightness.
/// `informative` is false for flat frames (black, white, fades), which look
/// alike in every episode and must never count as a match.
struct VisualSample: Sendable, Hashable {
    var time: Double
    var hash: UInt64
    var informative: Bool
}

/// One 32-bit audio sub-fingerprint (band-energy changes over ~0.26 s of
/// sound), taken every `AudioFingerprinter.hop` seconds.
struct AudioCode: Sendable, Hashable {
    var time: Double
    var code: UInt32
}

/// The fingerprints of a recorded segment, relative to its start.
struct SegmentPrint: Sendable, Equatable {
    var duration: Double
    /// Informative frames only, in time order.
    var visualTimes: [Float]
    var visualHashes: [UInt64]
    /// Contiguous audio codes; the first one sits `audioStart` seconds into
    /// the segment and the rest follow every `audioHop` seconds.
    var audioStart: Double
    var audioHop: Double
    var audioCodes: [UInt32]

    var hasVisual: Bool { visualHashes.count >= SegmentPrint.minimumVisualFrames }
    var hasAudio: Bool { audioCodes.count >= SegmentPrint.minimumAudioCodes }

    /// Fewer distinct frames than this can't be told apart from chance.
    static let minimumVisualFrames = 8
    /// About four seconds of sound.
    static let minimumAudioCodes = 128

    // MARK: File format
    //
    // "VSEG", version byte, then little-endian fields. Binary keeps a 90 s
    // intro to a few kilobytes and avoids property-list limits on UInt64.

    private static let magic: [UInt8] = Array("VSEG".utf8)
    private static let version: UInt8 = 1

    func encoded() -> Data {
        var data = Data()
        data.append(contentsOf: Self.magic)
        data.append(Self.version)
        data.appendLE(duration.bitPattern)
        data.appendLE(UInt32(visualHashes.count))
        for (time, hash) in zip(visualTimes, visualHashes) {
            data.appendLE(time.bitPattern)
            data.appendLE(hash)
        }
        data.appendLE(audioStart.bitPattern)
        data.appendLE(audioHop.bitPattern)
        data.appendLE(UInt32(audioCodes.count))
        for code in audioCodes { data.appendLE(code) }
        return data
    }

    init(duration: Double, visualTimes: [Float], visualHashes: [UInt64],
         audioStart: Double, audioHop: Double, audioCodes: [UInt32]) {
        self.duration = duration
        self.visualTimes = visualTimes
        self.visualHashes = visualHashes
        self.audioStart = audioStart
        self.audioHop = audioHop
        self.audioCodes = audioCodes
    }

    init?(data: Data) {
        var reader = ByteReader(data: data)
        guard reader.bytes(4) == Self.magic, reader.byte() == Self.version,
              let duration = reader.u64().map(Double.init(bitPattern:)),
              let visualCount = reader.u32(), visualCount < 1_000_000 else { return nil }
        var times: [Float] = []
        var hashes: [UInt64] = []
        times.reserveCapacity(Int(visualCount))
        hashes.reserveCapacity(Int(visualCount))
        for _ in 0..<visualCount {
            guard let time = reader.u32().map(Float.init(bitPattern:)), let hash = reader.u64() else { return nil }
            times.append(time)
            hashes.append(hash)
        }
        guard let audioStart = reader.u64().map(Double.init(bitPattern:)),
              let audioHop = reader.u64().map(Double.init(bitPattern:)),
              let audioCount = reader.u32(), audioCount < 10_000_000 else { return nil }
        var codes: [UInt32] = []
        codes.reserveCapacity(Int(audioCount))
        for _ in 0..<audioCount {
            guard let code = reader.u32() else { return nil }
            codes.append(code)
        }
        guard duration.isFinite, duration > 0 else { return nil }
        self.init(duration: duration, visualTimes: times, visualHashes: hashes,
                  audioStart: audioStart, audioHop: audioHop, audioCodes: codes)
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

private struct ByteReader {
    let data: Data
    var offset = 0

    mutating func bytes(_ count: Int) -> [UInt8]? {
        guard offset + count <= data.count else { return nil }
        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: count)
        offset += count
        return Array(data[start..<end])
    }

    mutating func byte() -> UInt8? { bytes(1)?.first }

    mutating func u32() -> UInt32? {
        guard let b = bytes(4) else { return nil }
        return b.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << (8 * UInt32($1.offset))) }
    }

    mutating func u64() -> UInt64? {
        guard let b = bytes(8) else { return nil }
        return b.enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << (8 * UInt64($1.offset))) }
    }
}

/// Recorded fingerprints, one file per segment, in Vela's Application
/// Support folder. They stay on this device; backups carry the segment
/// descriptions only.
enum SegmentLibrary {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Vela", isDirectory: true)
            .appendingPathComponent("Segments", isDirectory: true)
    }

    static func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).vseg")
    }

    static func save(_ print: SegmentPrint, id: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try print.encoded().write(to: url(for: id), options: [.atomic])
    }

    static func load(_ id: UUID) -> SegmentPrint? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return SegmentPrint(data: data)
    }

    static func exists(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(for: id).path)
    }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Removes files no saved segment refers to (after an import or reset).
    static func prune(keeping ids: Set<UUID>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "vseg" {
            let name = file.deletingPathExtension().lastPathComponent
            if let id = UUID(uuidString: name), ids.contains(id) { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
