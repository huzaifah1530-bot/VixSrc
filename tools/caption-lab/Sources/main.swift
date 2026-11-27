import AVFoundation
import Foundation
@preconcurrency import FluidAudio

// Caption lab: how well does Sortformer split dialogue by speaker?
//
// Ground truth comes from professional subtitles:
//   - a cue without "- " dash lines is one person talking, so any speaker
//     change inside it is a false split (what the viewer saw: "switches
//     while only one character is talking");
//   - a cue with two dash lines ("- Where were you? / - Out.") is a real
//     speaker change between its two parts.
// Words are spread over each cue by length, as the transcriber's timing
// would roughly be. Several labelling rules and model variants are
// scored, plus a timing-offset sweep to catch misalignment.
//
//   swift run -c release CaptionLab <name> [<name> …]   (reads lab/<name>.{aac,aif,json})

struct CueFile: Decodable { let audioStart: Double; let cues: [Cue] }
struct Cue: Decodable { let start: Double; let end: Double; let text: String }
struct Turn { let start: Double; let end: Double; let speaker: Int }
struct Word { let start: Double; let end: Double; let cue: Int; let part: Int }

func loadMono(_ url: URL) throws -> (samples: [Float], rate: Double) {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let format = file.processingFormat
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else { return ([], 0) }
    try file.read(into: buffer)
    let n = Int(buffer.frameLength), channels = Int(format.channelCount)
    var mono = [Float](repeating: 0, count: n)
    for c in 0..<channels { let p = buffer.floatChannelData![c]; for i in 0..<n { mono[i] += p[i] / Float(channels) } }
    return (mono, format.sampleRate)
}

/// Drops sound descriptions ("( arrows thunk )", "[MUSIC]") and speaker
/// tags ("NED:"), which aren't speech.
func spoken(_ line: String) -> String {
    var s = line.replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]|♪[^♪]*♪?"#, with: " ", options: .regularExpression)
    s = s.replacingOccurrences(of: #"^\s*[-–—]?\s*[A-Z][A-Z .']{1,20}:\s*"#, with: "- ", options: .regularExpression)
    return s.trimmingCharacters(in: .whitespaces)
}

func dashParts(_ text: String) -> [String] {
    let lines = text.components(separatedBy: "\n").map(spoken)
        .filter { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-–— ")).contains(where: \.isLetter) }
    let dashed = lines.filter { $0.hasPrefix("-") || $0.hasPrefix("–") || $0.hasPrefix("—") }
    if dashed.count >= 2 && dashed.count == lines.count { return lines }
    return [lines.joined(separator: " ")]
}

func words(for cues: [Cue]) -> [Word] {
    var out: [Word] = []
    for (ci, cue) in cues.enumerated() {
        let parts = dashParts(cue.text)
        let total = Double(parts.reduce(0) { $0 + max(1, $1.count) })
        var t = cue.start
        for (pi, part) in parts.enumerated() {
            let span = (cue.end - cue.start) * Double(max(1, part.count)) / total
            let tokens = part.split(separator: " ").filter { $0.contains(where: \.isLetter) }
            let chars = Double(tokens.reduce(0) { $0 + $1.count + 1 })
            var w = t
            for token in tokens {
                let d = span * Double(token.count + 1) / max(1, chars)
                out.append(Word(start: w, end: w + d, cue: ci, part: pi))
                w += d
            }
            t += span
        }
    }
    return out
}

/// Speaker of a word: the one with the most overlap, and how much of the
/// word that speaker covers.
func dominant(_ word: Word, _ turns: [Turn], shift: Double) -> (speaker: Int, share: Double)? {
    var overlap: [Int: Double] = [:]
    for turn in turns where turn.end + shift > word.start && turn.start + shift < word.end {
        overlap[turn.speaker, default: 0] += min(word.end, turn.end + shift) - max(word.start, turn.start + shift)
    }
    guard let best = overlap.max(by: { $0.value < $1.value }) else { return nil }
    return (best.key, best.value / max(0.01, word.end - word.start))
}

struct Rule { let name: String; let minShare: Double; let minRun: Double; let minWords: Int }

/// Labels per word under a rule: words below `minShare` take their
/// neighbour's speaker, and a speaker run shorter than `minRun` seconds or
/// `minWords` words is merged into the run before it.
func label(_ ws: [Word], _ turns: [Turn], _ rule: Rule, shift: Double) -> [Int?] {
    var labels: [Int?] = ws.map { w in
        guard let d = dominant(w, turns, shift: shift), d.share >= rule.minShare else { return nil }
        return d.speaker
    }
    var last: Int?
    for i in labels.indices { if labels[i] == nil { labels[i] = last } else { last = labels[i] } }
    guard rule.minRun > 0 || rule.minWords > 1 else { return labels }
    var i = 0
    var previous: Int?
    while i < labels.count {
        var j = i
        while j + 1 < labels.count, labels[j + 1] == labels[i] { j += 1 }
        let length = ws[j].end - ws[i].start, count = j - i + 1
        if let p = previous, labels[i] != p, length < rule.minRun || count < rule.minWords {
            for k in i...j { labels[k] = p }
        } else {
            previous = labels[i]
        }
        i = j + 1
    }
    return labels
}

struct Score { var falseSplit = 0; var single = 0; var hits = 0; var dashed = 0; var unlabeled = 0; var total = 0 }

func score(_ ws: [Word], _ labels: [Int?], cues: [Cue]) -> Score {
    var s = Score()
    var byCue: [Int: [(part: Int, label: Int?)]] = [:]
    for (w, l) in zip(ws, labels) { byCue[w.cue, default: []].append((w.part, l)); s.total += 1; if l == nil { s.unlabeled += 1 } }
    for (_, entries) in byCue {
        let parts = Set(entries.map(\.part))
        if parts.count == 1 {
            s.single += 1
            let ls = entries.compactMap(\.label)
            if Set(ls).count > 1 { s.falseSplit += 1 }
        } else if parts.count >= 2 {
            s.dashed += 1
            func major(_ p: Int) -> Int? {
                let ls = entries.filter { $0.part == p }.compactMap(\.label)
                return Dictionary(grouping: ls, by: { $0 }).max { $0.value.count < $1.value.count }?.key
            }
            if let a = major(0), let b = major(1), a != b { s.hits += 1 }
        }
    }
    return s
}

func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "  n/a" : String(format: "%5.1f%%", 100 * Double(a) / Double(b)) }

let rules = [
    Rule(name: "app now (every word)", minShare: 0, minRun: 0, minWords: 1),
    Rule(name: "share≥0.6", minShare: 0.6, minRun: 0, minWords: 1),
    Rule(name: "run≥0.8s,2w", minShare: 0, minRun: 0.8, minWords: 2),
    Rule(name: "share≥0.6 run≥0.8s,2w", minShare: 0.6, minRun: 0.8, minWords: 2),
    Rule(name: "APP: share≥0.6 run≥1s,2w", minShare: 0.6, minRun: 1.0, minWords: 2),
    Rule(name: "share≥0.6 run≥1.2s,3w", minShare: 0.6, minRun: 1.2, minWords: 3),
    Rule(name: "share≥0.6 run≥1.8s,4w", minShare: 0.6, minRun: 1.8, minWords: 4),
]

var configs: [(String, SortformerConfig)] = [("fast", .fastV2_1), ("balanced", .balancedV2_1)]
var high = SortformerConfig.highContextV2_1
high.precision = .palettized
configs.append(("high context (compressed)", high))

for name in CommandLine.arguments.dropFirst() {
    let base = URL(fileURLWithPath: "lab/\(name)")
    let audioURL = ["aac", "aif", "wav"].map { base.appendingPathExtension($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    guard let audioURL, let meta = try? JSONDecoder().decode(CueFile.self, from: Data(contentsOf: base.appendingPathExtension("json"))) else {
        print("skip \(name): missing files"); continue
    }
    let (samples, rate) = try loadMono(audioURL)
    let ws = words(for: meta.cues)
    print("\n================ \(name): \(String(format: "%.0f", Double(samples.count) / rate)) s audio, \(meta.cues.count) cues, \(ws.count) words")

    for (configName, config) in configs {
        let started = Date()
        let diarizer = SortformerDiarizer(config: config)
        do {
            let models = try await SortformerModels.loadFromHuggingFace(config: config)
            diarizer.initialize(models: models)
        } catch { print("  \(configName): couldn't load (\(error))"); continue }
        let step = Int(12 * rate)
        var offset = 0
        while offset < samples.count {
            _ = try diarizer.process(samples: samples[offset..<min(samples.count, offset + step)], sourceSampleRate: rate)
            offset += step
        }
        _ = try diarizer.finalizeSession()
        var turns: [Turn] = []
        for (index, speaker) in diarizer.timeline.speakers {
            for seg in speaker.finalizedSegments {
                turns.append(Turn(start: meta.audioStart + Double(seg.startTime), end: meta.audioStart + Double(seg.endTime), speaker: index))
            }
        }
        let speakers = Set(turns.map(\.speaker)).count
        print("\n  -- \(configName): \(turns.count) turns, \(speakers) speakers, \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        print("     rule                        falseSplit(single)  dashHit   unlabeled")
        for rule in rules {
            let s = score(ws, label(ws, turns, rule, shift: 0), cues: meta.cues)
            print("     \(rule.name.padding(toLength: 26, withPad: " ", startingAt: 0))  \(pct(s.falseSplit, s.single)) of \(s.single)   \(pct(s.hits, s.dashed)) of \(s.dashed)   \(pct(s.unlabeled, s.total))")
        }
        // Timing check: does shifting the speaker turns improve things?
        let probe = rules.first { $0.name.hasPrefix("APP") } ?? rules[3]
        var sweep: [String] = []
        for step in stride(from: -2.0, through: 2.0, by: 0.4) {
            let s = score(ws, label(ws, turns, probe, shift: step), cues: meta.cues)
            sweep.append(String(format: "%+.1fs:%@/%@", step, pct(s.falseSplit, s.single).trimmingCharacters(in: .whitespaces), pct(s.hits, s.dashed).trimmingCharacters(in: .whitespaces)))
        }
        print("     shift sweep (\(probe.name), false/hit): " + sweep.joined(separator: "  "))
    }
}
