import SwiftUI

/// The player's Settings panel: a list of options, each opening its own
/// page, in a scrollable glass card. A SwiftUI `Menu` was rebuilt every time
/// the player redrew (every playback tick), which jumped it back to the top
/// and broke scrolling; this panel keeps its own page and scroll position.
struct PlayerSettingsPanel: View {
    @Bindable var playerManager: VideoPlayerManager
    let options: PlayerOptions
    let zoom: PlayerZoomModel
    let captionsOn: Bool
    let onCaptionsOff: () -> Void
    let onGeneratedCaptions: (_ locale: String, _ translated: Bool) -> Void
    let onClose: () -> Void

    @AppStorage("vela_rotate_clockwise") private var rotateClockwise = true
    @AppStorage(CaptionSize.storageKey) private var captionScale = CaptionSize.medium.rawValue
    @State private var page: Page = .root
    /// Direction of the last page change, for the slide.
    @State private var forward = true
    @State private var contentHeight: CGFloat = 0

    enum Page: Hashable { case root, source, server, captions, captionStyle, rotate }

    private let pageSpring = Animation.spring(response: 0.34, dampingFraction: 0.86)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Tap outside to close.
                Color.black.opacity(0.35)
                    .contentShape(Rectangle())
                    .onTapGesture { onClose() }
                    .accessibilityHidden(true)

                card(maxHeight: max(160, geo.size.height - 24))
                    .frame(width: min(400, geo.size.width - 24))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .environment(\.colorScheme, .dark)
    }

    private func card(maxHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
            ScrollView {
                ZStack(alignment: .top) {
                    pageContent
                        .id(page)
                        .transition(.asymmetric(
                            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
                        ))
                }
                .padding(.vertical, 8)
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { contentHeight = proxy.size.height }
                            .onChange(of: proxy.size.height) { _, height in contentHeight = height }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            // As tall as the page needs, up to the screen; then it scrolls.
            .frame(height: min(max(contentHeight, 60), maxHeight - 52))
            .clipped()
        }
        .vixGlass(.strong, cornerRadius: 22)
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .animation(pageSpring, value: contentHeight)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            if page == .root {
                Text("Settings")
                    .font(.headline)
                    .padding(.leading, 8)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.white.opacity(0.14)))
                }
                .buttonStyle(PlayerButtonStyle())
                .accessibilityLabel("Close settings")
            } else {
                Button {
                    go(.root, forward: false)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                        Text(title(for: page))
                            .font(.headline)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                Spacer()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(height: 52)
    }

    private func title(for page: Page) -> String {
        switch page {
        case .root: return "Settings"
        case .source: return options.sourceLabel
        case .server: return "Server"
        case .captions: return "Captions"
        case .captionStyle: return "Caption Style"
        case .rotate: return "Rotate Direction"
        }
    }

    private func go(_ next: Page, forward: Bool = true) {
        self.forward = forward
        withAnimation(pageSpring) { page = next }
    }

    // MARK: Pages

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .root: rootPage
        case .source: sourcePage
        case .server: serverPage
        case .captions: captionsPage
        case .captionStyle:
            CaptionStyleEditor()
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        case .rotate: rotatePage
        }
    }

    private var rootPage: some View {
        VStack(spacing: 2) {
            if options.sources.count > 1 {
                navRow(options.sourceLabel, systemImage: "slider.horizontal.3",
                       value: options.sources.first(where: { $0.id == options.selectedSource })?.title, to: .source)
            }
            if options.servers.count > 1 {
                navRow("Server", systemImage: "server.rack",
                       value: options.servers.indices.contains(options.selectedServer) ? options.servers[options.selectedServer] : nil,
                       to: .server)
            }
            navRow("Captions", systemImage: "captions.bubble", value: captionValue, to: .captions)
                .disabled(!playerManager.hasAnySubtitles)
                .opacity(playerManager.hasAnySubtitles ? 1 : 0.45)
            navRow("Caption Style", systemImage: "textformat.size",
                   value: CaptionSize(rawValue: captionScale)?.label, to: .captionStyle)

            Toggle(isOn: Binding(get: { zoom.filled }, set: { zoom.setFill($0) })) {
                rowLabel("Zoom to Fill", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .tint(.white.opacity(0.85))
            .padding(.horizontal, 14)
            .frame(minHeight: 48)

            navRow("Rotate Direction", systemImage: rotateClockwise ? "rotate.right" : "rotate.left",
                   value: rotateClockwise ? "Clockwise" : "Counterclockwise", to: .rotate)
        }
        .padding(.horizontal, 6)
    }

    private var sourcePage: some View {
        let sections = options.sources.reduce(into: [String]()) { if !$0.contains($1.section) { $0.append($1.section) } }
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(sections, id: \.self) { section in
                if sections.count > 1 { sectionHeader(section) }
                ForEach(options.sources.filter { $0.section == section }) { choice in
                    choiceRow(choice.title, selected: choice.id == options.selectedSource) {
                        options.onSelectSource(choice.id)
                        onClose()
                    }
                }
            }
        }
        .padding(.horizontal, 6)
    }

    private var serverPage: some View {
        VStack(spacing: 2) {
            ForEach(Array(options.servers.enumerated()), id: \.offset) { index, name in
                choiceRow(name, selected: index == options.selectedServer) {
                    options.onSelectServer(index)
                    onClose()
                }
            }
        }
        .padding(.horizontal, 6)
    }

    private var captionsPage: some View {
        VStack(alignment: .leading, spacing: 2) {
            choiceRow("Off", selected: !captionsOn) {
                onCaptionsOff()
                onClose()
            }

            sectionHeader("Auto-generated")
            if playerManager.canGenerateCaptions {
                if playerManager.spokenAudioLanguage != "ja" {
                    choiceRow("English", selected: playerManager.generatedCaptionLocale == "en-US") {
                        onGeneratedCaptions("en-US", false)
                        onClose()
                    }
                }
                if options.isAnime && playerManager.spokenAudioLanguage != "en" {
                    choiceRow("Japanese",
                              selected: playerManager.generatedCaptionLocale == "ja-JP" && !playerManager.translateGeneratedCaptions) {
                        onGeneratedCaptions("ja-JP", false)
                        onClose()
                    }
                    choiceRow("Japanese → English",
                              selected: playerManager.generatedCaptionLocale == "ja-JP" && playerManager.translateGeneratedCaptions) {
                        onGeneratedCaptions("ja-JP", true)
                        onClose()
                    }
                }
            } else {
                Text(playerManager.generatedCaptionsUnavailableReason ?? "Auto-generated captions are unavailable on this device.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }

            if !playerManager.subtitleOptions.isEmpty {
                sectionHeader("This Video")
                ForEach(Array(playerManager.subtitleOptions.enumerated()), id: \.offset) { index, option in
                    choiceRow(option.displayName, selected: playerManager.selectedSubtitleIndex == index) {
                        playerManager.selectSubtitle(at: index)
                        onClose()
                    }
                }
            }
            if !playerManager.externalSubtitles.isEmpty {
                sectionHeader("Side-loaded")
                ForEach(Array(playerManager.externalSubtitles.enumerated()), id: \.offset) { index, track in
                    choiceRow(track.label, selected: playerManager.selectedExternalSubtitleIndex == index) {
                        playerManager.selectExternalSubtitle(at: index)
                        onClose()
                    }
                }
            }
        }
        .padding(.horizontal, 6)
    }

    private var rotatePage: some View {
        VStack(spacing: 2) {
            choiceRow("Clockwise", selected: rotateClockwise) {
                rotateClockwise = true
                go(.root, forward: false)
            }
            choiceRow("Counterclockwise", selected: !rotateClockwise) {
                rotateClockwise = false
                go(.root, forward: false)
            }
        }
        .padding(.horizontal, 6)
    }

    // MARK: Rows

    private func rowLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 24)
            Text(title)
                .font(.body)
        }
        .foregroundStyle(.white)
    }

    private func navRow(_ title: String, systemImage: String, value: String?, to destination: Page) -> some View {
        Button {
            go(destination)
        } label: {
            HStack(spacing: 8) {
                rowLabel(title, systemImage: systemImage)
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelRowStyle())
    }

    private func choiceRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .opacity(selected ? 1 : 0)
                    .frame(width: 24)
                Text(title)
                    .font(.body)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelRowStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Current caption choice for the Captions row.
    private var captionValue: String {
        if let locale = playerManager.generatedCaptionLocale {
            if locale == "ja-JP" {
                return playerManager.translateGeneratedCaptions ? "Japanese → English (Auto)" : "Japanese (Auto)"
            }
            return "English (Auto)"
        }
        if let index = playerManager.selectedSubtitleIndex, playerManager.subtitleOptions.indices.contains(index) {
            return playerManager.subtitleOptions[index].displayName
        }
        if let index = playerManager.selectedExternalSubtitleIndex, playerManager.externalSubtitles.indices.contains(index) {
            return playerManager.externalSubtitles[index].label
        }
        return "Off"
    }
}

/// Row highlight on press, like a system list.
private struct PanelRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.14 : 0))
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
