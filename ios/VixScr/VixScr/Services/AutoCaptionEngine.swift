import AVFoundation
import Foundation
import Speech

/// On-device captions made from the episode's own sound.
///
/// The sound comes from `HLSAudioFeed`, which decodes the stream's audio
/// segments itself and runs up to 30 seconds ahead of the picture. iOS's
/// decoded-audio output for the player (iOS 27) delivered nothing for the
/// hosts Vela uses, which is why captions used to stop at "No audio
/// received". Speech recognition runs on the device; nothing is uploaded.
@MainActor
final class AutoCaptionEngine {
    enum Failure: LocalizedError {
        case permission, unavailable, audioFormat

        var errorDescription: String? {
            switch self {
            case .permission: "Allow Speech Recognition in Settings to generate captions."
            case .unavailable: "On-device speech recognition is unavailable for this language."
            case .audioFormat: "This video does not provide audio for generated captions."
            }
        }
    }

    private struct Word: Sendable {
        let start: Double
        let end: Double
        let text: String
    }

    /// Longest stretch of audio handed to one recognition request.
    private static let windowSeconds = 24.0

    private var feed: HLSAudioFeed?
    private var listener: UUID?
    private var recognizer: SFSpeechRecognizer?
    private var pending: [AudioChunk] = []
    private var worker: Task<Void, Never>?
    private var currentTask: SFSpeechRecognitionTask?
    private var retainedCues: [SubtitleCue] = []
    private var onCues: ([SubtitleCue]) -> Void = { _ in }
    private var onStatus: (String) -> Void = { _ in }
    private var playbackTime: () -> Double = { 0 }
    private var generation = 0
    private var resultCount = 0

    /// Nonisolated on purpose: Speech calls this handler on a background queue.
    /// A closure formed inside this @MainActor class would inherit main-actor
    /// isolation, and Swift 6 traps when it runs off the main thread.
    nonisolated static func authorize() async -> Bool {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }
        return status == .authorized
    }

    func start(feed: HLSAudioFeed, locale: Locale, playbackTime: @escaping () -> Double,
               onStatus: @escaping (String) -> Void = { _ in },
               onCues: @escaping ([SubtitleCue]) -> Void) throws {
        stop()
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw Failure.unavailable
        }
        self.recognizer = recognizer
        self.feed = feed
        self.onCues = onCues
        self.onStatus = onStatus
        self.playbackTime = playbackTime
        resultCount = 0
        onStatus("Loading the episode's sound…")
        listener = feed.listen({ [weak self] chunk in
            self?.receive(chunk)
        }, state: { [weak self] state in
            guard let self else { return }
            if case .failed(let message) = state { self.onStatus("Captions can't read this stream's sound: \(message)") }
        })
    }

    /// The playhead jumped; the feed starts over there, and so do we.
    func noteSeek(to time: Double) {
        generation += 1
        pending.removeAll()
        currentTask?.cancel()
        currentTask = nil
        worker?.cancel()
        worker = nil
        // Cues already made stay; they're still right for their times.
    }

    func stop() {
        if let listener { feed?.stopListening(listener) }
        listener = nil
        feed = nil
        generation += 1
        worker?.cancel()
        worker = nil
        currentTask?.cancel()
        currentTask = nil
        pending.removeAll()
        retainedCues = []
    }

    // MARK: Recognition

    private func receive(_ chunk: AudioChunk) {
        // Behind the playhead already (a slow start): no use transcribing.
        guard chunk.end > playbackTime() - 2 else { return }
        if resultCount == 0 { onStatus("Listening…") }
        pending.append(chunk)
        if worker == nil { startWorker() }
    }

    private func startWorker() {
        let generation = generation
        worker = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, generation == self.generation, !self.pending.isEmpty {
                let window = self.takeWindow()
                await self.recognize(window, generation: generation)
            }
            if let self, generation == self.generation { self.worker = nil }
        }
    }

    /// Up to `windowSeconds` of consecutive chunks, merged.
    private func takeWindow() -> AudioChunk {
        var samples: [Float] = []
        let first = pending.removeFirst()
        samples.append(contentsOf: first.samples)
        var end = first.end
        while let next = pending.first, next.rate == first.rate, abs(next.start - end) < 0.1,
              end - first.start + next.duration <= Self.windowSeconds {
            pending.removeFirst()
            samples.append(contentsOf: next.samples)
            end = next.end
        }
        return AudioChunk(start: first.start, rate: first.rate, samples: samples)
    }

    private func recognize(_ chunk: AudioChunk, generation: Int) async {
        guard let recognizer,
              let format = AVAudioFormat(standardFormatWithSampleRate: chunk.rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
        chunk.samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: chunk.samples.count)
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.append(buffer)
        request.endAudio()

        let offset = chunk.start
        let outcome: Outcome = await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            currentTask = Self.makeTask(recognizer: recognizer, request: request, offset: offset) { outcome in
                once.resume(continuation, with: outcome)
            }
        }
        guard generation == self.generation else { return }
        currentTask = nil
        switch outcome {
        case .words(let words):
            accept(words, from: chunk.start, to: chunk.end)
        case .failed(let message):
            if resultCount == 0 { onStatus("Speech recognition error: \(message)") }
        }
    }

    private enum Outcome: Sendable {
        case words([Word])
        case failed(String)
    }

    /// Starts one request; `deliver` gets its final result. Nonisolated:
    /// Speech calls back on its own queue, and a closure formed in this
    /// main-actor class would trap there.
    nonisolated private static func makeTask(recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
                                             offset: Double, deliver: @escaping @Sendable (Outcome) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { @Sendable result, error in
            if let error {
                let ns = error as NSError
                // 1110: no speech in this stretch; 216/301: cancelled.
                let quiet = [216, 301, 1110].contains(ns.code)
                deliver(quiet ? .words([]) : .failed("\(ns.domain) \(ns.code): \(ns.localizedDescription)"))
                return
            }
            guard let result, result.isFinal else { return }
            let words = result.bestTranscription.segments.map {
                Word(start: offset + $0.timestamp, end: offset + $0.timestamp + $0.duration, text: $0.substring)
            }
            deliver(.words(words))
        }
    }

    private func accept(_ words: [Word], from start: Double, to end: Double) {
        if !words.isEmpty {
            if resultCount == 0 { onStatus("") }
            resultCount += 1
        }
        var fresh: [SubtitleCue] = []
        var group: [Word] = []
        func finishGroup() {
            guard let first = group.first, let last = group.last else { return }
            let text = CaptionText.format(group.map(\.text).joined(separator: " "))
            fresh.append(SubtitleCue(start: first.start, end: last.end + 0.7, text: text))
            group.removeAll()
        }
        for word in words {
            if let last = group.last, word.start - last.end > 1.2 { finishGroup() }
            group.append(word)
            if group.count >= 9 || word.text.hasSuffix(".") || word.text.hasSuffix("?") || word.text.hasSuffix("!") {
                finishGroup()
            }
        }
        finishGroup()
        retainedCues.removeAll { $0.start >= start - 0.05 && $0.start < end }
        retainedCues.append(contentsOf: fresh)
        retainedCues.sort { $0.start < $1.start }
        if retainedCues.count > 1_500 { retainedCues.removeFirst(retainedCues.count - 1_500) }
        onCues(retainedCues)
    }
}

/// Resumes a continuation once, whichever Speech callback comes first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func resume<T>(_ continuation: CheckedContinuation<T, Never>, with value: T) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        continuation.resume(returning: value)
    }
}

/// Speech-to-text output is close to caption-ready but still needs a light
/// pass so numbers read naturally on screen (grouped digits, no bare "one
/// thousand two hundred"). Punctuation comes from `addsPunctuation`.
enum CaptionText {
    private static let numberRuns = try? NSRegularExpression(pattern: "\\b\\d{4,9}\\b")

    static func format(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        out = out.replacingOccurrences(of: " ,", with: ",")
        out = out.replacingOccurrences(of: " .", with: ".")
        // Group long digit runs: 1000000 → 1,000,000. Years and short
        // numbers are left alone so "1999" stays a year.
        guard let numberRuns else { return out }
        let range = NSRange(out.startIndex..., in: out)
        var result = ""
        var cursor = out.startIndex
        for match in numberRuns.matches(in: out, range: range) {
            guard let r = Range(match.range, in: out) else { continue }
            result += String(out[cursor..<r.lowerBound])
            result += grouped(String(out[r]))
            cursor = r.upperBound
        }
        result += String(out[cursor...])
        return result
    }

    private static func grouped(_ digits: String) -> String {
        guard digits.count >= 5 || (digits.count == 4 && !isYear(digits)) else { return digits }
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return out
    }

    private static func isYear(_ digits: String) -> Bool {
        guard let value = Int(digits) else { return false }
        return (1000...2099).contains(value)
    }
}
