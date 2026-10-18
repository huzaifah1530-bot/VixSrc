import SwiftUI

/// Stands in for the video frame while playback is on a computer: shows
/// what's playing there and controls it. Same 16:9 glass card, poster
/// backdrop and skip / play controls as the on-phone player.
struct RemotePlayerView: View {
    @State private var link = DeviceLink.shared
    @Environment(AppStore.self) private var store
    /// Fallback artwork from the sheet's own selection.
    var poster: URL?
    var onPlayHere: () -> Void

    /// Position the thumb shows while dragging and until the computer catches up.
    @State private var scrub: Double?
    /// Latest dragged value. SwiftUI can report "editing ended" before the
    /// final value lands, so the send is deferred a beat and reads this.
    @State private var pendingSeek: Double?
    @State private var seekGeneration = 0
    @State private var spinBack = 0.0
    @State private var spinForward = 0.0

    private var state: RemoteState? { link.remote }
    private var desk: String { link.playbackTarget?.name ?? "your computer" }

    var body: some View {
        ZStack {
            backdrop
            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 10) {
                header
                Spacer(minLength: 0)
                if link.isConnected, let state, state.open {
                    transport(state)
                    Spacer(minLength: 0)
                    timeline(state)
                } else {
                    statusView
                    Spacer(minLength: 0)
                }
            }
            .padding(14)
        }
    }

    // MARK: Pieces

    @ViewBuilder private var backdrop: some View {
        let url = state?.poster.flatMap(URL.init(string:)) ?? poster
        Color.black
        if let url {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill().blur(radius: 24).opacity(0.7)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "desktopcomputer")
            VStack(alignment: .leading, spacing: 1) {
                Text(link.isConnected ? "Playing on \(desk)" : desk)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.7))
                if let state, state.open {
                    Text([state.title, state.subtitle].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
    }

    private func sourceMenu(_ state: RemoteState) -> some View {
        Menu {
            ForEach(["Sub", "Dub", ""], id: \.self) { audio in
                let entries = Array(state.sources.enumerated()).filter { ($0.element.audio ?? "") == audio }
                if !entries.isEmpty {
                    Section(audio == "Sub" ? "Subtitled" : audio == "Dub" ? "Dubbed" : "Source") {
                        ForEach(entries, id: \.offset) { index, source in
                            Button {
                                link.command("source", ["index": index])
                            } label: {
                                if index == state.sourceIndex { Label(source.quality ?? source.name, systemImage: "checkmark") }
                                else { Text(source.quality ?? source.name) }
                            }
                        }
                    }
                }
            }
        } label: {
            Label(state.sources.indices.contains(state.sourceIndex) ? (state.sources[state.sourceIndex].quality ?? state.sources[state.sourceIndex].name) : "Quality",
                  systemImage: "slider.horizontal.3")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .vixGlass(.regular, cornerRadius: 14)
        }
    }

    private func transport(_ state: RemoteState) -> some View {
        let seconds = Double(store.seekInterval)
        return HStack(spacing: 34) {
            Button {
                withAnimation(.spring(response: 0.7, dampingFraction: 0.55)) { spinBack -= 360 }
                link.command("skip", ["by": -seconds])
            } label: {
                Image(systemName: "gobackward.\(store.seekInterval)")
                    .font(.system(size: 26, weight: .semibold))
                    .rotationEffect(.degrees(spinBack))
            }
            .accessibilityLabel("Back \(store.seekInterval) seconds")

            Button {
                link.command("toggle")
            } label: {
                Image(systemName: state.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .frame(width: 64, height: 64)
                    .vixGlass(.strong, cornerRadius: 32)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(state.playing ? "Pause" : "Play")

            Button {
                withAnimation(.spring(response: 0.7, dampingFraction: 0.55)) { spinForward += 360 }
                link.command("skip", ["by": seconds])
            } label: {
                Image(systemName: "goforward.\(store.seekInterval)")
                    .font(.system(size: 26, weight: .semibold))
                    .rotationEffect(.degrees(spinForward))
            }
            .accessibilityLabel("Forward \(store.seekInterval) seconds")
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .disabled(!state.controllable)
        .opacity(state.controllable ? 1 : 0.4)
    }

    private func timeline(_ state: RemoteState) -> some View {
        let duration = max(state.duration, 1)
        let shown = scrub ?? state.position
        return VStack(spacing: 4) {
            if state.controllable && state.duration > 0 {
                Slider(value: Binding(get: { shown }, set: { scrub = $0; pendingSeek = $0 }), in: 0...duration, onEditingChanged: { editing in
                    if editing {
                        seekGeneration += 1
                    } else {
                        commitSeek()
                    }
                })
                .tint(.white)
                HStack {
                    Text(Self.time(shown))
                    Spacer()
                    Text("-" + Self.time(max(0, state.duration - shown)))
                }
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
            } else {
                Text(state.mode == "embed" ? "This server's player doesn't report its time; use its own controls on \(desk)." : (state.status ?? state.error ?? "Starting…"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// Sends exactly one seek per drag, with the final value. The thumb keeps
    /// showing that value until the computer reports it (or 3s pass), so it
    /// doesn't snap back between frames.
    private func commitSeek() {
        let gen = seekGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard gen == seekGeneration, let target = pendingSeek else { return }
            pendingSeek = nil
            link.command("seek", ["to": target])
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard gen == seekGeneration else { return }
                if let pos = link.remote?.position, abs(pos - target) < 3 { break }
            }
            if gen == seekGeneration { scrub = nil }
        }
    }

    @ViewBuilder private var statusView: some View {
        VStack(spacing: 10) {
            switch link.phase {
            case .connecting:
                ProgressView().tint(.white)
                Text("Connecting to \(desk)…").font(.caption.weight(.semibold))
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(message).font(.caption.weight(.semibold)).multilineTextAlignment(.center)
                buttons
            case .connected:
                if let error = state?.error {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text(error).font(.caption.weight(.semibold)).multilineTextAlignment(.center)
                } else {
                    ProgressView().tint(.white)
                    Text(state?.status ?? "Waiting for \(desk)…").font(.caption.weight(.semibold))
                }
            case .idle:
                Text("Not connected to \(desk).").font(.caption.weight(.semibold))
                buttons
            }
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 20)
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button("Reconnect") { if let id = link.playbackTargetId { link.connect(id, auto: false) } }
            Button("Play on iPhone") { link.setPlaybackTarget(nil); onPlayHere() }
        }
        .font(.caption.weight(.bold))
        .buttonStyle(.bordered)
        .tint(.white)
    }

    static func time(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s), h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
