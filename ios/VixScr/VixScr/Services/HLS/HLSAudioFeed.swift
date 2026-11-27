import Foundation

/// The playing episode's sound, decoded by Vela from the stream's own
/// segments (`HLSStreamReader`), kept up to `lookahead` seconds ahead of the
/// playhead. On-device captions and sound-based segment detection both
/// listen to it. Because it runs ahead, both are ready before the moment
/// they're needed.
@MainActor
final class HLSAudioFeed {
    enum State: Equatable {
        case starting
        case running
        case failed(String)
    }

    private(set) var state: State = .starting
    /// Long enough that captions are always transcribed before they play.
    var lookahead: Double = 45

    private let reader: HLSStreamReader
    private let playbackTime: () -> Double
    private var listeners: [UUID: (AudioChunk) -> Void] = [:]
    private var task: Task<Void, Never>?
    /// Playlist time decoded up to.
    private var cursor: Double?
    private var generation = 0
    private var onState: [UUID: (State) -> Void] = [:]

    init(reader: HLSStreamReader, playbackTime: @escaping () -> Double) {
        self.reader = reader
        self.playbackTime = playbackTime
    }

    /// Starts listening. Audio already passed isn't replayed; a listener
    /// joining late gets everything from the playhead on.
    @discardableResult
    func listen(_ handler: @escaping (AudioChunk) -> Void, state: ((State) -> Void)? = nil) -> UUID {
        let id = UUID()
        listeners[id] = handler
        if let state {
            onState[id] = state
            state(self.state)
        }
        // A new listener wants audio from now, not from where others are.
        restart()
        return id
    }

    func stopListening(_ id: UUID) {
        listeners[id] = nil
        onState[id] = nil
        if listeners.isEmpty { stop() }
    }

    /// The playhead jumped: start decoding from there.
    func noteSeek() {
        guard !listeners.isEmpty else { return }
        restart()
    }

    func stop() {
        task?.cancel()
        task = nil
        generation += 1
        cursor = nil
    }

    private func restart() {
        stop()
        guard !listeners.isEmpty else { return }
        let generation = generation
        task = Task { @MainActor [weak self] in
            await self?.run(generation)
        }
    }

    private func setState(_ new: State) {
        guard new != state else { return }
        state = new
        for handler in onState.values { handler(new) }
    }

    private func run(_ generation: Int) async {
        var failures = 0
        while !Task.isCancelled, generation == self.generation {
            let now = playbackTime()
            do {
                if cursor == nil || cursor! < now - 2 || cursor! > now + lookahead + 30 {
                    cursor = try await reader.audioSegmentStart(at: max(0, now - 0.5))
                }
                guard generation == self.generation, let from = cursor else { return }
                if from >= now + lookahead {
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                }
                let duration = await reader.duration
                if duration > 0, from >= duration - 0.05 {
                    // The end of the episode: wait in case of a seek back.
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                let chunks = try await reader.audio(from: from, to: from + 12)
                guard !Task.isCancelled, generation == self.generation else { return }
                failures = 0
                setState(.running)
                for chunk in chunks {
                    for listener in listeners.values { listener(chunk) }
                }
                // Always move on, even past a piece with no sound in it.
                if let reach = chunks.last?.playlistEnd, reach > from {
                    cursor = reach
                } else {
                    cursor = try await reader.audioSegmentsEnd(from: from, to: from + 12)
                }
            } catch {
                guard !Task.isCancelled, generation == self.generation else { return }
                if case HLSStreamReader.Failure.unsupported = error {
                    setState(.failed(error.localizedDescription))
                    return
                }
                // Network trouble: keep trying, backing off to 10 seconds.
                failures += 1
                if failures >= 3 { setState(.failed(error.localizedDescription)) }
                try? await Task.sleep(for: .seconds(min(10, Double(failures) * 2)))
            }
        }
    }
}
