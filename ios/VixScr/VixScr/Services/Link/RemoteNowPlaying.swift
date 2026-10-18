import Foundation
import AVFoundation
import MediaPlayer
import UIKit

/// Lock screen / Control Center player for what's playing on a paired
/// computer. iOS only keeps a background app running (and its network
/// connection open) while it's playing audio, so while a remote session is
/// active we loop silence; the real picture and sound are on the computer.
/// Play/pause/skip/scrub from the lock screen are sent as link commands,
/// and the info mirrors the live state the computer reports.
@MainActor
final class RemoteNowPlaying {
    static let shared = RemoteNowPlaying()

    private(set) var isActive = false
    private var silence: AVAudioPlayer?
    private var targets: [(MPRemoteCommand, Any)] = []
    private var artworkURL: String?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?

    /// Call with every state update while the phone is routing playback.
    func update(_ state: RemoteState?, connected: Bool, enabled: Bool) {
        guard enabled, connected, let state, state.open else { stop(); return }
        start()
        publish(state)
    }

    private func start() {
        guard !isActive else { return }
        isActive = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        silence = try? AVAudioPlayer(data: Self.silentWAV)
        silence?.numberOfLoops = -1
        silence?.volume = 0.01
        silence?.play()
        installCommands()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        silence?.stop()
        silence = nil
        removeCommands()
        artworkTask?.cancel()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if UIApplication.shared.applicationState != .active {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func publish(_ state: RemoteState) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: state.title.isEmpty ? "Vela" : state.title,
            MPMediaItemPropertyArtist: "Playing on \(DeviceLink.shared.playbackTarget?.name ?? "computer")",
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.position,
            MPNowPlayingInfoPropertyPlaybackRate: state.playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if let subtitle = state.subtitle { info[MPMediaItemPropertyAlbumTitle] = subtitle }
        if state.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = state.duration }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = state.playing ? .playing : .paused

        let center = MPRemoteCommandCenter.shared()
        center.changePlaybackPositionCommand.isEnabled = state.controllable && state.duration > 0
        center.nextTrackCommand.isEnabled = state.hasNext
        loadArtwork(state.poster)
    }

    private func loadArtwork(_ poster: String?) {
        guard poster != artworkURL else { return }
        artworkURL = poster
        artwork = nil
        artworkTask?.cancel()
        guard let poster, let url = URL(string: poster) else { return }
        artworkTask = Task { @MainActor [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url), !Task.isCancelled,
                  let image = UIImage(data: data) else { return }
            self?.artwork = Self.makeArtwork(image)
            if let state = DeviceLink.shared.remote { self?.publish(state) }
        }
    }

    private nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    // MARK: Commands → computer

    private func installCommands() {
        removeCommands()
        let center = MPRemoteCommandCenter.shared()
        let seconds = Double(UserDefaults.standard.integer(forKey: "vixsrc_live_seek_interval")).nonZero ?? 10
        func add(_ command: MPRemoteCommand, _ handler: @escaping @MainActor (MPRemoteCommandEvent) -> Void) {
            command.isEnabled = true
            let token = command.addTarget { event in
                MainActor.assumeIsolated { handler(event) }
                return .success
            }
            targets.append((command, token))
        }
        add(center.playCommand) { _ in DeviceLink.shared.command("play") }
        add(center.pauseCommand) { _ in DeviceLink.shared.command("pause") }
        add(center.togglePlayPauseCommand) { _ in DeviceLink.shared.command("toggle") }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: seconds)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: seconds)]
        add(center.skipForwardCommand) { _ in DeviceLink.shared.command("skip", ["by": seconds]) }
        add(center.skipBackwardCommand) { _ in DeviceLink.shared.command("skip", ["by": -seconds]) }
        add(center.nextTrackCommand) { _ in DeviceLink.shared.command("next") }
        add(center.changePlaybackPositionCommand) { event in
            if let e = event as? MPChangePlaybackPositionCommandEvent { DeviceLink.shared.command("seek", ["to": e.positionTime]) }
        }
    }

    private func removeCommands() {
        for (command, token) in targets {
            command.removeTarget(token)
            command.isEnabled = false
        }
        targets.removeAll()
    }

    /// One second of 8 kHz mono 16-bit silence.
    private static let silentWAV: Data = {
        let samples = 8000, bytes = samples * 2
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + bytes))
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(bytes))
        d.append(Data(count: bytes))
        return d
    }()
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
