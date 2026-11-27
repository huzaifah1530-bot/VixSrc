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
    /// Who is speaking when (`SpeakerTracker`), for speaker-change lines.
    private var speakers: SpeakerTracker?
    static let speakersKey = "vela_caption_speakers"
    private var speakersEnabled: Bool { UserDefaults.standard.object(forKey: Self.speakersKey) as? Bool ?? true }

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
            let modern = LongFormTranscriber(onWords: { [weak self] words, from, to, isFinal in
                self?.accept(words.map { Word(start: $0.start, end: $0.end, text: $0.text) }, from: from, to: to, isFinal: isFinal)
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
        if speakersEnabled {
            let tracker = SpeakerTracker()
            tracker.onChange = { [weak self] time in self?.rebuild(from: time - 2) }
            tracker.start()
            speakers = tracker
        }
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
                self.onDiagnostics?(self.diagnostics())
            }
        }
        listener = feed.listen({ [weak self] chunk in
            self?.receive(chunk)
        }, state: { [weak self] state in
            guard let self else { return }
            if case .failed(let message) = state { self.onStatus("Captions can't read this stream's sound: \(message)") }
        })
    }

    /// The playhead jumped. Captions already made stay and show at once;
    /// the iOS 26 session keeps running and is simply given the new sound.
    /// The older engine drops its queued clips.
    func noteSeek(to time: Double) {
        if modernActive { return }
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
        finalWords = []
        roughWords = []
        builtCues = []
        speakers?.stop()
        speakers = nil
    }

    // MARK: Diagnostics

    /// "Sound +40 s · Text +31 s · iOS 26 engine · Dialogue on".
    private func diagnostics() -> String {
        let now = playbackTime()
        var parts: [String] = []
        if #available(iOS 26.0, *), let modern = modern as? LongFormTranscriber {
            parts.append("Sound +\(Int(modern.sentAhead(of: now))) s")
            parts.append("iOS 26 engine")
        } else {
            let ahead = buffer.isEmpty ? 0 : max(0, bufferEnd - now)
            parts.append("Sound +\(Int(ahead)) s · \(pending.count) clips queued")
            parts.append("Older engine")
        }
        // The last line already made in the stretch of captions around now.
        let cues = builtCues.filter { $0.start >= now - 30 }
        var reach = now
        for cue in cues where cue.start <= reach + 12 { reach = max(reach, cue.end) }
        parts.insert("Text +\(Int(max(0, reach - now))) s", at: 1)
        if let next = cues.first(where: { $0.end > now }) {
            parts.append(next.start <= now ? "Showing" : "Next line in \(String(format: "%.1f", next.start - now)) s")
        }
        return parts.joined(separator: " · ")
    }

    private func cancelRecognitions() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        running = 0
    }

    // MARK: Recognition

    private var modernActive: Bool {
        if #available(iOS 26.0, *) { return modern is LongFormTranscriber }
        return false
    }

    var onDiagnostics: ((String) -> Void)?

    private func receive(_ raw: AudioChunk) {
        // Behind the playhead already (a slow start): no use transcribing.
        guard raw.end > playbackTime() - 1 else { return }
        var chunk = raw
        if #available(iOS 26.0, *), let modern = modern as? LongFormTranscriber {
            // Already sent (the viewer skipped back): its captions exist.
            guard let unsent = modern.unsent(raw) else { return }
            chunk = unsent
        }
        speakers?.feed(chunk)
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

    // MARK: Lines
    //
    // The recognised words are kept, and lines are rebuilt from them around
    // whatever changed: new final words, new rough words, or the speaker
    // model reaching that stretch (it often lands a second or two after
    // the words do).

    private var finalWords: [Word] = []
    /// Rough words (iOS 26), shown until the final text for them arrives.
    private var roughWords: [Word] = []
    private var builtCues: [SubtitleCue] = []

    private func accept(_ words: [Word], from start: Double, to end: Double, isFinal: Bool = true) {
        if !words.isEmpty {
            if resultCount == 0 { onStatus("") }
            resultCount += 1
        }
        if isFinal {
            finalWords.removeAll { $0.start >= start - 0.05 && $0.start < end }
            finalWords.append(contentsOf: words)
            finalWords.sort { $0.start < $1.start }
            if finalWords.count > 40_000 { finalWords.removeFirst(finalWords.count - 40_000) }
            // Rough words for this stretch are replaced by the final ones.
            roughWords.removeAll { $0.start < end + 0.05 && $0.end > start - 0.05 }
        } else {
            // Each rough result is the newest guess for the stretch it covers.
            roughWords.removeAll { $0.end > start - 0.05 }
            roughWords.append(contentsOf: words)
        }
        rebuild(from: start)
    }

    /// Rebuilds the lines from just before `time` onwards.
    private func rebuild(from time: Double) {
        // Start at a line boundary before the change, and never in the
        // middle of a two-speaker pair.
        let cut = builtCues.last { $0.start < time - 1 && !$0.text.contains("\n") }?.start ?? -.infinity
        builtCues.removeAll { $0.start >= cut }
        let words = (finalWords + roughWords).filter { $0.start >= cut }.sorted { $0.start < $1.start }

        // Japanese / Chinese words come without spaces between them.
        let joiner = spacedLanguage ? " " : ""
        let maxLength = spacedLanguage ? 42 : 22
        func line(_ words: [Word]) -> String { CaptionText.format(words.map(\.text).joined(separator: joiner)) }
        let enders: Set<Character> = [".", "?", "!", "。", "？", "！", "…"]

        var lines: [(words: [Word], speaker: Int?)] = []
        var group: [Word] = []
        var groupSpeaker: Int?
        func finish() {
            guard !group.isEmpty else { return }
            lines.append((group, groupSpeaker))
            group = []
            groupSpeaker = nil
        }
        for word in words {
            let speaker = speakers?.speaker(from: word.start, to: max(word.end, word.start + 0.1))
            if let last = group.last {
                // A pause, a new speaker, or a line that would get too long
                // starts a new line.
                let newSpeaker = speaker != nil && groupSpeaker != nil && speaker != groupSpeaker
                if newSpeaker || word.start - last.end > 0.8 || line(group + [word]).count > maxLength { finish() }
            }
            group.append(word)
            if groupSpeaker == nil { groupSpeaker = speaker }
            if let end = word.text.last, enders.contains(end) { finish() }
        }
        finish()

        var index = 0
        while index < lines.count {
            let first = lines[index]
            guard let firstStart = first.words.first?.start, let firstEnd = first.words.last?.end else { index += 1; continue }
            let firstText = line(first.words)
            // Two speakers back to back: both on screen, an em dash each,
            // the reply added when it's spoken.
            if index + 1 < lines.count, let a = first.speaker, let b = lines[index + 1].speaker, a != b,
               let replyStart = lines[index + 1].words.first?.start, let replyEnd = lines[index + 1].words.last?.end,
               replyStart - firstEnd < 1.5 {
                let replyText = line(lines[index + 1].words)
                builtCues.append(SubtitleCue(start: firstStart, end: replyStart, text: "— " + firstText))
                builtCues.append(SubtitleCue(start: replyStart, end: replyEnd + 0.7, text: "— \(firstText)\n— \(replyText)"))
                index += 2
            } else {
                builtCues.append(SubtitleCue(start: firstStart, end: firstEnd + 0.7, text: firstText))
                index += 1
            }
        }
        if builtCues.count > 8_000 { builtCues.removeFirst(builtCues.count - 8_000) }

        var shown = builtCues
        // One line at a time: each ends when the next begins, so a new line
        // replaces the last instead of stacking under it.
        for i in shown.indices.dropLast() where shown[i].end > shown[i + 1].start {
            let cue = shown[i]
            shown[i] = SubtitleCue(start: cue.start, end: shown[i + 1].start, text: cue.text)
        }
        onCues(shown)
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
