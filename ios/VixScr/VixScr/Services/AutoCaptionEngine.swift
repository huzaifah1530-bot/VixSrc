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

    /// Longest stretch of audio handed to one recognition request (the
    /// iOS 17–25 engine). Longer gives the recognizer more context.
    private static let windowSeconds = 15.0
    /// Recognitions running at once. iOS cancels an on-device recognition
    /// when another starts, so this must stay 1; 10-second windows on the
    /// device finish well within 10 seconds, and old audio is skipped.
    private static let parallelRequests = 1

    private var feed: HLSAudioFeed?
    private var listener: UUID?
    /// One recognizer per parallel request.
    private var recognizers: [SFSpeechRecognizer] = []
    private var nextRecognizer = 0
    private var pending: [Window] = []
    private var running = 0
    private var ticker: Task<Void, Never>?
    private var tasks: [UUID: SFSpeechRecognitionTask] = [:]
    private var retainedCues: [SubtitleCue] = []
    private var onCues: ([SubtitleCue]) -> Void = { _ in }
    private var onStatus: (String) -> Void = { _ in }
    private var playbackTime: () -> Double = { 0 }
    private var generation = 0
    private var resultCount = 0
    private var windowsDone = 0
    /// iOS 26+: Apple's long-form transcriber (`LongFormTranscriber`).
    private var modern: AnyObject?
    private var spacedLanguage = true
    /// Names to listen for: the title, its cast and characters.
    private var vocabulary: [String] = []

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

    func start(feed: HLSAudioFeed, locale: Locale, vocabulary: [String] = [], playbackTime: @escaping () -> Double,
               onStatus: @escaping (String) -> Void = { _ in },
               onCues: @escaping ([SubtitleCue]) -> Void) throws {
        stop()
        let language = locale.language.languageCode?.identifier ?? "en"
        spacedLanguage = !["ja", "zh", "yue", "th"].contains(language)
        self.vocabulary = vocabulary
        // The older recognizer: the fallback on iOS 26+, the only engine below.
        let made = (0..<Self.parallelRequests).compactMap { _ in SFSpeechRecognizer(locale: locale) }
            .filter { $0.isAvailable && $0.supportsOnDeviceRecognition }
        if #available(iOS 26.0, *) {
            let modern = LongFormTranscriber(onWords: { [weak self] words, from, to in
                self?.accept(words.map { Word(start: $0.start, end: $0.end, text: $0.text) }, from: from, to: to)
            }, onStatus: { [weak self] status in
                self?.onStatus(status)
            })
            self.modern = modern
            Task { @MainActor [weak self] in
                do {
                    try await modern.start(locale: locale, vocabulary: vocabulary)
                    guard let self, self.modern === modern else { return }
                    if self.resultCount == 0 { self.onStatus("Listening…") }
                } catch {
                    guard let self, self.modern === modern else { return }
                    modern.stop()
                    self.modern = nil
                    if self.recognizers.isEmpty {
                        self.onStatus("On-device speech recognition isn't available for this language.")
                    }
                }
            }
        } else if made.isEmpty {
            throw Failure.unavailable
        }
        recognizers = made
        self.feed = feed
        self.onCues = onCues
        self.onStatus = onStatus
        self.playbackTime = playbackTime
        resultCount = 0
        windowsDone = 0
        onStatus("Loading the episode's sound…")
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.flushIfStarved()
                self.fillWorkers()
            }
        }
        listener = feed.listen({ [weak self] chunk in
            self?.receive(chunk)
        }, state: { [weak self] state in
            guard let self else { return }
            if case .failed(let message) = state { self.onStatus("Captions can't read this stream's sound: \(message)") }
        })
    }

    /// The playhead jumped; the feed starts over there, and so do we.
    func noteSeek(to time: Double) {
        if #available(iOS 26.0, *), let modern = modern as? LongFormTranscriber { modern.restart() }
        generation += 1
        pending.removeAll()
        buffer = []
        cancelRecognitions()
        // Cues already made stay; they're still right for their times.
    }

    func stop() {
        if #available(iOS 26.0, *), let modern = modern as? LongFormTranscriber { modern.stop() }
        modern = nil
        if let listener { feed?.stopListening(listener) }
        listener = nil
        feed = nil
        generation += 1
        ticker?.cancel()
        ticker = nil
        cancelRecognitions()
        pending.removeAll()
        buffer = []
        recognizers = []
        retainedCues = []
    }

    private func cancelRecognitions() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        running = 0
    }

    // MARK: Recognition

    private func receive(_ chunk: AudioChunk) {
        // Behind the playhead already (a slow start): no use transcribing.
        guard chunk.end > playbackTime() - 1 else { return }
        if #available(iOS 26.0, *), let modern = modern as? LongFormTranscriber {
            modern.feed(chunk)
            return
        }
        guard !recognizers.isEmpty else { return }
        if resultCount == 0 { onStatus("Listening…") }
        let continuous = !buffer.isEmpty && chunk.rate == bufferRate && abs(chunk.start - bufferEnd) < 0.1
        if !continuous {
            cutWindows(flush: true)
            buffer = chunk.samples
            bufferStart = chunk.start
            bufferRate = chunk.rate
            nextWindowStart = max(chunk.start, playbackTime() - 0.5)
        } else {
            buffer.append(contentsOf: chunk.samples)
        }
        cutWindows(flush: false)
        fillWorkers()
    }

    // MARK: Windows
    //
    // The sound arrives as one continuous stream, cut into 10-second
    // windows. Each window is recognised with a second of overlap on both
    // sides so no word is cut in half, and keeps only the words that start
    // inside its own 10 seconds; the neighbour has the rest.

    private struct Window {
        let audio: AudioChunk
        let keep: Range<Double>
    }

    private static let overlap = 2.0
    private var buffer: [Float] = []
    private var bufferStart = 0.0
    private var bufferRate = 48_000.0
    private var nextWindowStart = 0.0
    private var bufferEnd: Double { bufferStart + Double(buffer.count) / bufferRate }

    /// Cuts every full window out of the buffer; with `flush`, the rest too.
    private func cutWindows(flush: Bool) {
        guard !buffer.isEmpty else { return }
        while nextWindowStart + Self.windowSeconds + Self.overlap <= bufferEnd
                || (flush && nextWindowStart < bufferEnd - 0.3) {
            let keepEnd = min(nextWindowStart + Self.windowSeconds, bufferEnd)
            let from = max(bufferStart, nextWindowStart - Self.overlap)
            let to = min(bufferEnd, keepEnd + Self.overlap)
            let first = Int((from - bufferStart) * bufferRate)
            let last = min(buffer.count, Int((to - bufferStart) * bufferRate))
            if last > first {
                pending.append(Window(audio: AudioChunk(start: from, rate: bufferRate, samples: Array(buffer[first..<last])),
                                      keep: nextWindowStart..<keepEnd))
            }
            nextWindowStart = keepEnd
        }
        // Keep only what the next window's lead-in needs.
        let keepFrom = nextWindowStart - Self.overlap
        let drop = min(buffer.count, max(0, Int((keepFrom - bufferStart) * bufferRate)))
        if drop > 0 {
            buffer.removeFirst(drop)
            bufferStart += Double(drop) / bufferRate
        }
        if flush {
            buffer = []
        }
    }

    /// The playhead is catching up with the decoded sound (the end of the
    /// episode, or a slow download): recognise the partial window now.
    private func flushIfStarved() {
        guard !buffer.isEmpty, pending.isEmpty, bufferEnd < playbackTime() + Self.windowSeconds else { return }
        cutWindows(flush: true)
        fillWorkers()
    }

    /// Up to `parallelRequests` recognitions at once, always on the audio
    /// nearest the playhead. Audio that has already played is dropped, so
    /// if recognition ever falls behind it skips ahead instead of
    /// transcribing the past.
    private func fillWorkers() {
        let now = playbackTime()
        // Only windows that have fully played are dropped; one still playing
        // is worth finishing.
        pending.removeAll { $0.keep.upperBound < now - 1 }
        pending.sort { $0.keep.lowerBound < $1.keep.lowerBound }
        while running < Self.parallelRequests, !pending.isEmpty {
            let window = pending.removeFirst()
            running += 1
            let generation = generation
            Task { @MainActor [weak self] in
                await self?.recognize(window, generation: generation)
                guard let self, generation == self.generation else { return }
                self.running -= 1
                self.fillWorkers()
            }
        }
    }

    private func recognize(_ window: Window, generation: Int) async {
        let chunk = window.audio
        guard let recognizer = recognizers.isEmpty ? nil : recognizers[nextRecognizer % recognizers.count],
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
        request.contextualStrings = Array(vocabulary.prefix(100))
        request.append(buffer)
        request.endAudio()

        nextRecognizer += 1
        let offset = chunk.start
        let id = UUID()
        // A recognition that never answers must not stall captions.
        let deadline = max(15, chunk.duration * 3)
        let outcome: Outcome = await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            tasks[id] = Self.makeTask(recognizer: recognizer, request: request, offset: offset) { outcome in
                once.resume(continuation, with: outcome)
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(deadline))
                once.resume(continuation, with: .words([]))
                self?.tasks[id]?.cancel()
            }
        }
        tasks[id]?.cancel()
        tasks[id] = nil
        guard generation == self.generation else { return }
        windowsDone += 1
        switch outcome {
        case .words(let words):
            accept(words.filter { window.keep.contains($0.start) }, from: window.keep.lowerBound, to: window.keep.upperBound)
            if resultCount == 0, windowsDone >= 4 {
                onStatus("Sound is coming in, but no speech has been recognised yet.")
            }
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
        // Japanese / Chinese words come without spaces between them.
        let joiner = spacedLanguage ? " " : ""
        let maxLength = spacedLanguage ? 42 : 22
        func line(_ words: [Word]) -> String { words.map(\.text).joined(separator: joiner) }
        func finishGroup() {
            guard let first = group.first, let last = group.last else { return }
            fresh.append(SubtitleCue(start: first.start, end: last.end + 0.7, text: CaptionText.format(line(group))))
            group.removeAll()
        }
        let enders: Set<Character> = [".", "?", "!", "。", "？", "！", "…"]
        for word in words {
            // A pause, or a line that would get too long, starts a new line.
            if let last = group.last,
               word.start - last.end > 0.8 || line(group + [word]).count > maxLength { finishGroup() }
            group.append(word)
            if let end = word.text.last, enders.contains(end) { finishGroup() }
        }
        finishGroup()
        retainedCues.removeAll { $0.start >= start - 0.05 && $0.start < end }
        retainedCues.append(contentsOf: fresh)
        retainedCues.sort { $0.start < $1.start }
        if retainedCues.count > 1_500 { retainedCues.removeFirst(retainedCues.count - 1_500) }
        // One line at a time: each ends when the next begins, so a new line
        // replaces the last instead of stacking under it.
        for i in retainedCues.indices.dropLast() where retainedCues[i].end > retainedCues[i + 1].start {
            let cue = retainedCues[i]
            retainedCues[i] = SubtitleCue(start: cue.start, end: retainedCues[i + 1].start, text: cue.text)
        }
        onCues(retainedCues)
    }
}

/// Resumes a continuation once, whichever Speech callback comes first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func resume<T: Sendable>(_ continuation: CheckedContinuation<T, Never>, with value: T) {
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
        for mark in [",", ".", "?", "!", ";", ":", "'s", "n't"] {
            out = out.replacingOccurrences(of: " " + mark, with: mark)
        }
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
