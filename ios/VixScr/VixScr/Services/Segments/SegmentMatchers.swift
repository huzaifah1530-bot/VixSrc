import Foundation

/// How sure a matcher must be before it calls a match, 0...1. The viewer
/// sets it per segment ("Match Confidence"): low finds more, including
/// re-cut or re-coloured versions, and risks false matches; high only
/// takes near-identical footage or sound. 0.5 is the tested default.
typealias MatchConfidence = Double

/// Finds a recorded segment's frames in live playback.
///
/// Every informative live frame is compared with the recorded frames; each
/// close one (small Hamming distance of 64 bits) votes for where the
/// segment would have started (`live time − recorded time`). Footage that
/// really is the segment piles its votes onto one start time; chance
/// look-alikes scatter. A match needs several different live frames, and
/// several different recorded frames, agreeing within half a second.
struct VisualMatcher {
    let times: [Double]
    let hashes: [UInt64]
    let duration: Double

    private let maxDistance: Int
    private let minLiveFrames: Int
    private let minReferenceFrames: Int
    private let minSpan: Double

    /// Strongest candidates kept per live frame, so a still image that
    /// resembles many recorded frames can't flood the vote.
    private static let votesPerFrame = 6
    private static let window = 15.0
    private static let cluster = 0.6

    private struct Vote { let live: Double; let start: Double; let reference: Int }
    private var votes: [Vote] = []

    init?(print: SegmentPrint, confidence: MatchConfidence = 0.5) {
        guard print.hasVisual else { return nil }
        times = print.visualTimes.map(Double.init)
        hashes = print.visualHashes
        duration = print.duration
        let c = min(1, max(0, confidence))
        // 0.5 → distance 10, 6 live / 5 recorded frames over 1.5 s.
        maxDistance = Int((14 - 8 * c).rounded())
        minLiveFrames = 3 + Int((6 * c).rounded())
        minReferenceFrames = 2 + Int((6 * c).rounded())
        minSpan = 0.5 + 2 * c
    }

    mutating func reset() { votes.removeAll() }

    /// The live start time of the segment once it's recognised.
    mutating func add(_ sample: VisualSample) -> Double? {
        votes.removeAll { $0.live < sample.time - Self.window || $0.live > sample.time + 1 }
        guard sample.informative else { return nil }

        var candidates: [(distance: Int, index: Int)] = []
        for (index, hash) in hashes.enumerated() {
            let distance = (hash ^ sample.hash).nonzeroBitCount
            if distance <= maxDistance { candidates.append((distance, index)) }
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
            guard liveFrames.count >= minLiveFrames, referenceFrames.count >= minReferenceFrames,
                  let first = group.map(\.live).min(), let last = group.map(\.live).max(),
                  last - first >= minSpan else { continue }
            let score = liveFrames.count + referenceFrames.count
            if best == nil || score > best!.score { best = (score, group.map(\.start)) }
        }
        guard let starts = best?.starts.sorted(), !starts.isEmpty else { return nil }
        return starts[starts.count / 2]
    }
}

/// Finds a recorded segment's sound by sliding the last two seconds of live
/// audio codes along the recording and measuring the bit error rate.
/// Unrelated audio sits near 50 % errors; the same audio, even re-encoded,
/// sits well under 30 %.
struct AudioMatcher {
    let codes: [UInt32]
    let start: Double
    let hop: Double
    let duration: Double

    /// Codes compared at a time: about two seconds.
    static let blockLength = 64
    private static let checkEvery = 8
    private let threshold: Double
    private let strongThreshold: Double

    private var live: [AudioCode] = []
    private var sinceCheck = 0
    private var pending: Double?

    init?(print: SegmentPrint, confidence: MatchConfidence = 0.5) {
        guard print.hasAudio, print.audioCodes.count > Self.blockLength else { return nil }
        codes = print.audioCodes
        start = print.audioStart
        hop = print.audioHop > 0 ? print.audioHop : AudioFingerprinter.hop
        duration = print.duration
        let c = min(1, max(0, confidence))
        // 0.5 → 30 % errors, or 20 % for a single-check match.
        threshold = 0.38 - 0.16 * c
        strongThreshold = threshold - 0.10
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

        let maxErrors = Int(Double(Self.blockLength * 32) * threshold)
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
        if rate <= strongThreshold { pending = nil; return segmentStart }
        // A weaker hit counts once the next check agrees with it.
        if let previous = pending, abs(previous - segmentStart) < 0.25 { pending = nil; return segmentStart }
        pending = segmentStart
        return nil
    }
}
