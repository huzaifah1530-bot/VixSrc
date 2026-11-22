import AVFoundation
import CoreMedia
import Speech

/// On-device transcription of the HLS audio already being played. The iOS 27
/// sample-buffer output is required: it supplies decoded audio without using
/// the microphone or uploading the program to a service.
@available(iOS 27.0, *)
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

    private weak var item: AVPlayerItem?
    private var output: AVPlayerItemSampleBufferOutput?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var pullTask: Task<Void, Never>?
    private var baseTime = 0.0
    private var lastTimestamp = -1.0
    private var pendingSeek: Double?
    private var retainedCues: [SubtitleCue] = []
    private var onCues: ([SubtitleCue]) -> Void = { _ in }

    static func authorize() async -> Bool {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        return status == .authorized
    }

    func start(item: AVPlayerItem, locale: Locale, playbackTime: @escaping () -> Double,
               onCues: @escaping ([SubtitleCue]) -> Void) throws {
        stop()
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw Failure.unavailable
        }
        guard let pcm = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
            throw Failure.audioFormat
        }
        var asbd = pcm.streamDescription.pointee
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                             layoutSize: 0, layout: nil, magicCookieSize: 0,
                                             magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &description) == noErr,
              let description else { throw Failure.audioFormat }
        let configuration = AVPlayerItemSampleBufferOutputAudioConfiguration()
        configuration.requestedAudioFormat = description
        let output = AVPlayerItemSampleBufferOutput(configuration: configuration)
        item.add(output)
        self.item = item
        self.output = output
        self.onCues = onCues

        pullTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let next = await output.nextSampleBuffer() {
                let sample = next.sampleBuffer
                guard sample.sampleCount > 0 else { continue }
                let timestamp = sample.presentationTimeStamp.seconds
                guard timestamp.isFinite else { continue }

                // A seek (or a restart of the underlying sequence) invalidates
                // the recognizer's timeline, so start a fresh request anchored
                // at the new position instead of emitting cues with the old
                // offset.
                if let seek = self.pendingSeek {
                    self.pendingSeek = nil
                    if abs(seek - timestamp) < 12 {
                        self.startRecognition(recognizer: recognizer, at: timestamp)
                        self.lastTimestamp = timestamp
                        continue
                    }
                }
                let jumped = self.lastTimestamp >= 0 && abs(timestamp - self.lastTimestamp) > 2.5
                if next.sequenceWasRestarted || jumped || self.request == nil || timestamp - self.baseTime >= 50 {
                    self.startRecognition(recognizer: recognizer, at: timestamp)
                }
                self.lastTimestamp = timestamp

                // Do not transcribe far ahead of the picture or retain the
                // entire episode's decoded audio in memory.
                let start = playbackTime()
                while !Task.isCancelled, timestamp > playbackTime() + 8 {
                    try? await Task.sleep(for: .milliseconds(200))
                    // The viewer seeked backwards; drop this decoded sample and
                    // let the next one (from the new position) restart us.
                    if playbackTime() < start - 1.5 { break }
                }
                guard !Task.isCancelled else { break }
                if playbackTime() < start - 1.5 {
                    self.startRecognition(recognizer: recognizer, at: playbackTime())
                    self.lastTimestamp = timestamp
                    continue
                }
                sample.withUnsafeSampleBuffer { unsafe in
                    self.request?.appendAudioSampleBuffer(unsafe)
                }
            }
            self.request?.endAudio()
        }
    }

    /// Called by the player after a seek so the recognizer restarts at the new
    /// playhead instead of continuing the old timeline.
    func noteSeek(to time: Double) {
        pendingSeek = time
        lastTimestamp = -1
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
    }

    private func startRecognition(recognizer: SFSpeechRecognizer, at timestamp: Double) {
        request?.endAudio()
        recognitionTask?.cancel()
        request = nil
        baseTime = timestamp
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.request = request
        let offset = timestamp
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let result, error == nil else { return }
            let words = result.bestTranscription.segments.map {
                Word(start: offset + $0.timestamp,
                     end: offset + $0.timestamp + $0.duration,
                     text: $0.substring)
            }
            Task { @MainActor [weak self] in self?.accept(words, from: offset) }
        }
    }

    private func accept(_ words: [Word], from offset: Double) {
        guard offset == baseTime else { return }
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
        retainedCues.removeAll { $0.start >= offset - 0.2 }
        retainedCues.append(contentsOf: fresh)
        if retainedCues.count > 1_200 { retainedCues.removeFirst(retainedCues.count - 1_200) }
        onCues(retainedCues)
    }

    func stop() {
        pullTask?.cancel()
        pullTask = nil
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        if let item, let output { item.remove(output) }
        item = nil
        output = nil
        retainedCues = []
        lastTimestamp = -1
        pendingSeek = nil
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
