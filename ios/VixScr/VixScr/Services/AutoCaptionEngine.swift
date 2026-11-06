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
                if next.sequenceWasRestarted || self.request == nil || timestamp - self.baseTime >= 50 {
                    self.startRecognition(recognizer: recognizer, at: timestamp)
                }
                // Do not transcribe far ahead of the picture or retain the
                // entire episode's decoded audio in memory.
                while !Task.isCancelled, timestamp > playbackTime() + 8 {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                guard !Task.isCancelled else { break }
                sample.withUnsafeSampleBuffer { unsafe in
                    self.request?.appendAudioSampleBuffer(unsafe)
                }
            }
            self.request?.endAudio()
        }
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
            fresh.append(SubtitleCue(start: first.start, end: last.end + 0.7,
                                     text: group.map(\.text).joined(separator: " ")))
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
    }
}
