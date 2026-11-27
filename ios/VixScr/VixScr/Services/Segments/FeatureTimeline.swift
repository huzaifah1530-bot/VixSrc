import Foundation

/// Everything the segment recorder has fingerprinted so far, by time. The
/// recorder keeps it filling while the viewer watches and scrubs, so a part
/// they already watched can be saved without playing it again.
struct FeatureTimeline {
    private(set) var frames: [VisualSample] = []
    /// Unbroken stretches of audio codes. A seek starts a new one.
    private(set) var audioRuns: [[AudioCode]] = []

    mutating func add(_ sample: VisualSample) {
        // Keep time order; replay of a stretch replaces nothing, it just
        // skips frames already held within 0.1 s.
        let index = insertionIndex(for: sample.time)
        if index < frames.count, abs(frames[index].time - sample.time) < 0.1 { return }
        if index > 0, abs(frames[index - 1].time - sample.time) < 0.1 { return }
        frames.insert(sample, at: index)
    }

    mutating func add(_ codes: [AudioCode]) {
        for code in codes {
            if var last = audioRuns.last, let previous = last.last,
               abs(code.time - previous.time - AudioFingerprinter.hop) <= AudioFingerprinter.hop * 1.5 {
                last.append(code)
                audioRuns[audioRuns.count - 1] = last
            } else {
                audioRuns.append([code])
            }
        }
        // Tiny fragments from seeking around are useless.
        if audioRuns.count > 40 { audioRuns.removeAll { $0.count < 32 } }
    }

    private func insertionIndex(for time: Double) -> Int {
        var low = 0, high = frames.count
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].time < time { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Share of the range with a frame in every half second.
    func visualCoverage(from start: Double, to end: Double) -> Double {
        guard end > start else { return 0 }
        let bins = max(1, Int(((end - start) / 0.5).rounded(.up)))
        var seen = Set<Int>()
        var index = insertionIndex(for: start)
        while index < frames.count, frames[index].time <= end {
            seen.insert(min(bins - 1, Int((frames[index].time - start) / 0.5)))
            index += 1
        }
        return Double(seen.count) / Double(bins)
    }

    /// An unbroken run of audio that spans the range, if there is one.
    func audioRun(from start: Double, to end: Double) -> [AudioCode]? {
        let tolerance = 0.35
        return audioRuns
            .filter { run in
                guard let first = run.first, let last = run.last else { return false }
                return first.time <= start + tolerance && last.time >= end - tolerance
            }
            .max { $0.count < $1.count }?
            .filter { $0.time >= start && $0.time <= end }
    }

    /// The range is fingerprinted well enough to save for this method.
    func isCaptured(from start: Double, to end: Double, method: DetectionMethod, audioPossible: Bool) -> Bool {
        let picture = visualCoverage(from: start, to: end) >= 0.85
        let sound = audioPossible && audioRun(from: start, to: end) != nil
        switch method {
        case .visual: return picture
        case .audio: return audioPossible ? sound : picture
        case .both: return picture && (sound || !audioPossible)
        }
    }

    func print(from start: Double, to end: Double) -> SegmentPrint {
        var times: [Float] = []
        var hashes: [UInt64] = []
        var index = insertionIndex(for: start)
        while index < frames.count, frames[index].time <= end {
            let frame = frames[index]
            if frame.informative {
                times.append(Float(frame.time - start))
                hashes.append(frame.hash)
            }
            index += 1
        }
        let run = audioRun(from: start, to: end) ?? []
        return SegmentPrint(
            duration: end - start,
            visualTimes: times,
            visualHashes: hashes,
            audioStart: run.first.map { $0.time - start } ?? 0,
            audioHop: AudioFingerprinter.hop,
            audioCodes: run.map(\.code)
        )
    }
}
