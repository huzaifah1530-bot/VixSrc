import Foundation

/// Finds a recorded segment's frames in live playback.
///
/// Every informative live frame is compared with the recorded frames; each
/// close one (Hamming distance ≤ `maxDistance` of 64 bits) votes for where
/// the segment would have started (`live time − recorded time`). Footage
/// that really is the segment piles its votes onto one start time; chance
/// look-alikes scatter. A match needs several different live frames, and
/// several different recorded frames, agreeing within half a second.
struct VisualMatcher {
    let times: [Double]
    let hashes: [UInt64]
    let duration: Double

    static let maxDistance = 10
    /// Strongest candidates kept per live frame, so a still image that
    /// resembles many recorded frames can't flood the vote.
    private static let votesPerFrame = 6
    private static let window = 15.0
    private static let cluster = 0.6
    private static let minLiveFrames = 6
    private static let minReferenceFrames = 5
    private static let minSpan = 1.5

    private struct Vote { let live: Double; let start: Double; let reference: Int }
    private var votes: [Vote] = []

    init?(print: SegmentPrint) {
        guard print.hasVisual else { return nil }
        times = print.visualTimes.map(Double.init)
        hashes = print.visualHashes
        duration = print.duration
    }

    mutating func reset() { votes.removeAll() }

    /// The live start time of the segment once it's recognised.
    mutating func add(_ sample: VisualSample) -> Double? {
        votes.removeAll { $0.live < sample.time - Self.window || $0.live > sample.time + 1 }
        guard sample.informative else { return nil }

        var candidates: [(distance: Int, index: Int)] = []
        for (index, hash) in hashes.enumerated() {
            let distance = (hash ^ sample.hash).nonzeroBitCount
            if distance <= Self.maxDistance { candidates.append((distance, index)) }
        }
        guard !candidates.isEmpty else { return nil }
        candidates.sort { $0.distance < $1.distance }
        for candidate in candidates.prefix(Self.votesPerFrame) {
            votes.append(Vote(live: sample.time, start: sample.time - times[candidate.index], reference: candidate.index))
        }
        return bestCluster()
    }

    private func bestCluster() -> Double? {
        let sorted = votes.sorted { $0.start < $1.start }
        var best: (score: Int, starts: [Double])?
        var lower = 0
        for upper in sorted.indices {
            while sorted[upper].start - sorted[lower].start > Self.cluster { lower += 1 }
            let group = sorted[lower...upper]
            let liveFrames = Set(group.map { Int(($0.live * 10).rounded()) })
            let referenceFrames = Set(group.map(\.reference))
            guard liveFrames.count >= Self.minLiveFrames, referenceFrames.count >= Self.minReferenceFrames,
                  let first = group.map(\.live).min(), let last = group.map(\.live).max(),
                  last - first >= Self.minSpan else { continue }
            let score = liveFrames.count + referenceFrames.count
            if best == nil || score > best!.score { best = (score, group.map(\.start)) }
        }
        guard let starts = best?.starts.sorted(), !starts.isEmpty else { return nil }
        return starts[starts.count / 2]
    }
}

/// Finds a recorded segment's sound in live playback by sliding the last
/// two seconds of live audio codes along the recording and measuring the
/// bit error rate. Unrelated audio sits near 50 % errors; the same audio,
/// even re-encoded, sits well under 30 %.
struct AudioMatcher {
    let codes: [UInt32]
    let start: Double
    let hop: Double
    let duration: Double

    /// Codes compared at a time: about two seconds.
    static let blockLength = 64
    private static let threshold = 0.30
    private static let strongThreshold = 0.20
    private static let checkEvery = 8

    private var live: [AudioCode] = []
    private var sinceCheck = 0
    private var pending: Double?

    init?(print: SegmentPrint) {
        guard print.hasAudio, print.audioCodes.count > Self.blockLength else { return nil }
        codes = print.audioCodes
        start = print.audioStart
        hop = print.audioHop > 0 ? print.audioHop : AudioFingerprinter.hop
        duration = print.duration
    }

    mutating func reset() {
        live.removeAll()
        sinceCheck = 0
        pending = nil
    }

    mutating func add(_ newCodes: [AudioCode]) -> Double? {
        var result: Double?
        for code in newCodes {
            // A jump in the timeline (seek, new run) starts over.
            if let last = live.last, abs(code.time - last.time - hop) > hop * 1.5 { reset() }
            live.append(code)
            if live.count > Self.blockLength * 2 { live.removeFirst(live.count - Self.blockLength * 2) }
            sinceCheck += 1
            if live.count >= Self.blockLength, sinceCheck >= Self.checkEvery {
                sinceCheck = 0
                if let found = check() { result = found }
            }
        }
        return result
    }

    private mutating func check() -> Double? {
        let block = live.suffix(Self.blockLength)
        let blockCodes = block.map(\.code)
        // Mostly digital silence: nothing to recognise.
        guard blockCodes.filter({ $0 == 0 }).count * 5 < Self.blockLength,
              let blockStart = block.first?.time else { pending = nil; return nil }

        let maxErrors = Int(Double(Self.blockLength * 32) * Self.threshold)
        var bestErrors = Int.max
        var bestPosition = -1
        let positions = codes.count - Self.blockLength
        for position in 0...positions {
            var errors = 0
            var i = 0
            while i < Self.blockLength {
                errors += (codes[position + i] ^ blockCodes[i]).nonzeroBitCount
                if errors >= bestErrors || errors > maxErrors { break }
                i += 1
            }
            if i == Self.blockLength, errors < bestErrors {
                bestErrors = errors
                bestPosition = position
            }
        }
        guard bestPosition >= 0 else { pending = nil; return nil }
        let rate = Double(bestErrors) / Double(Self.blockLength * 32)
        let segmentStart = blockStart - (start + Double(bestPosition) * hop)
        if rate <= Self.strongThreshold { pending = nil; return segmentStart }
        // A weaker hit counts once the next check agrees with it.
        if let previous = pending, abs(previous - segmentStart) < 0.25 { pending = nil; return segmentStart }
        pending = segmentStart
        return nil
    }
}
