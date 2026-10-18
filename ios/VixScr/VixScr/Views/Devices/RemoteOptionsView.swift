import SwiftUI

/// Quality (Sub / Dub) and Captions for what's playing on the computer,
/// in the same row style as the sheet's Server selector. Changes apply on
/// the computer's player.
struct RemoteOptionsView: View {
    @State private var link = DeviceLink.shared

    var body: some View {
        if let state = link.remote, state.open, link.isConnected {
            VStack(spacing: 12) {
                if !state.sources.isEmpty { qualityRow(state) }
                captionsRow(state)
            }
        }
    }

    private func qualityRow(_ state: RemoteState) -> some View {
        row(title: state.sources.contains { $0.audio != nil } ? "Audio & Quality" : "Source", icon: "slider.horizontal.3") {
            Menu {
                ForEach(["Sub", "Dub", ""], id: \.self) { audio in
                    let entries = Array(state.sources.enumerated()).filter { ($0.element.audio ?? "") == audio }
                    if !entries.isEmpty {
                        Section(audio == "Sub" ? "Subtitled" : audio == "Dub" ? "Dubbed" : "Sources") {
                            ForEach(entries, id: \.offset) { index, source in
                                Button { link.command("source", ["index": index]) } label: {
                                    if index == state.sourceIndex { Label(source.quality ?? source.name, systemImage: "checkmark") }
                                    else { Text(source.quality ?? source.name) }
                                }
                            }
                        }
                    }
                }
            } label: {
                menuLabel(sourceLabel(state))
            }
        }
    }

    private func sourceLabel(_ state: RemoteState) -> String {
        guard state.sources.indices.contains(state.sourceIndex) else { return "Select" }
        let s = state.sources[state.sourceIndex]
        return [s.quality ?? s.name, s.audio].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private func captionsRow(_ state: RemoteState) -> some View {
        let tracks = state.captions ?? []
        let index = state.captionIndex ?? -1
        row(title: "Captions", icon: "captions.bubble") {
            if tracks.isEmpty {
                Text(state.mode == "embed" ? "Set on the computer" : "None")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                Menu {
                    Button { link.command("caption", ["index": -1]) } label: {
                        if index < 0 { Label("Off", systemImage: "checkmark") } else { Text("Off") }
                    }
                    ForEach(Array(tracks.enumerated()), id: \.offset) { i, name in
                        Button { link.command("caption", ["index": i]) } label: {
                            if i == index { Label(name, systemImage: "checkmark") } else { Text(name) }
                        }
                    }
                } label: {
                    menuLabel(tracks.indices.contains(index) ? tracks[index] : "Off")
                }
            }
        }
    }

    private func menuLabel(_ text: String) -> some View {
        Label(text, systemImage: "chevron.up.chevron.down")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.blue)
    }

    private func row<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            content()
        }
        .padding(14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
