import SwiftUI

struct PlayerSheet: View {
    @Bindable var viewModel: CatalogViewModel
    @Environment(\.glassFidelity) private var fidelity

    var body: some View {
        NavigationStack {
            portraitLayout
                .background(VixTheme.background.ignoresSafeArea())
            .navigationTitle(viewModel.selected?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 8) {
                        PlaybackTargetMenu { viewModel.startPlaybackForCurrentSelection() }
                        PartyButton(host: viewModel)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.closePlayer()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
            }
        }
        // The sheet covers Home's toast, so the player shows its own.
        .overlay(alignment: .bottom) {
            if let toast = viewModel.toastMessage {
                ToastView(message: toast)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.25), value: viewModel.toastMessage)
        // Link prompts must come from the front-most presentation.
        .deviceLinkPrompts()
        .overlay(alignment: .top) { PartyBanner() }
        .partyPrompts()
        .onAppear { if PartySession.shared.active { PartySession.shared.attach(viewModel) } }
        // Keep the episode list in step with what the computer is playing.
        .onChange(of: DeviceLink.shared.remote) { _, state in
            guard DeviceLink.shared.routesPlayback, DeviceLink.shared.shouldFollowRemote, let state else { return }
            Task { await viewModel.followRemote(state) }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Subviews

    private var portraitLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                playerFrame
                    .padding(.horizontal, 20)
                nextEpisodeButton
                    .padding(.horizontal, 20)
                serverSelectorView
                    .padding(.horizontal, 20)
                if DeviceLink.shared.routesPlayback {
                    RemoteOptionsView()
                        .padding(.horizontal, 20)
                }
                nativeSourceSelectorView
                    .padding(.horizontal, 20)
                actionRow
                    .padding(.horizontal, 20)
                introTimes
                    .padding(.horizontal, 20)
                descriptionView
                    .padding(.horizontal, 20)
                metaLine
                    .padding(.horizontal, 20)
                // CastRow manages its own horizontal padding internally
                // so it can scroll edge-to-edge without being clipped.
                castSection
                episodeSection
                    .padding(.horizontal, 20)
            }
            .padding(.vertical, 20)
        }
    }

    @ViewBuilder private var nextEpisodeButton: some View {
        if viewModel.selected?.type == .tv, let label = viewModel.nextEpisodeLabel {
            NextEpisodeButton(label: label) {
                Task { await viewModel.playNextEpisode() }
            }
        }
    }

    @ViewBuilder private var serverSelectorView: some View {
        if viewModel.store.servers.count > 1 {
            ServerSelector(viewModel: viewModel)
        }
    }

    @ViewBuilder private var nativeSourceSelectorView: some View {
        if viewModel.nativeSources.count > 1 {
            HStack {
                Label("Source", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(Array(viewModel.nativeSources.enumerated()), id: \.offset) { index, source in
                        sourceButton(source.name, index: index)
                    }
                } label: {
                    Label(viewModel.nativeSources[viewModel.selectedNativeSourceIndex].name,
                          systemImage: "chevron.up.chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.blue)
                }
            }
            .padding(14)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func sourceButton(_ title: String, index: Int) -> some View {
        Button {
            viewModel.switchNativeSource(to: index)
        } label: {
            if index == viewModel.selectedNativeSourceIndex {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    @ViewBuilder private var descriptionView: some View {
        if let description = viewModel.selected?.description {
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }

    @ViewBuilder private var castSection: some View {
        if !viewModel.cast.isEmpty {
            CastRow(cast: viewModel.cast)
        }
    }

    @ViewBuilder private var episodeSection: some View {
        if viewModel.selected?.type == .tv {
            EpisodeHub(viewModel: viewModel)
        }
    }

    // MARK: - Player frame

    @ViewBuilder
    private var playerFrame: some View {
        ZStack {
            Group {
                if DeviceLink.shared.routesPlayback {
                    RemotePlayerView(poster: viewModel.selected?.backdropURL ?? viewModel.selected?.posterURL) {
                        viewModel.startPlaybackForCurrentSelection()
                    }
                } else if viewModel.currentNativeVideoURL != nil || viewModel.playerManager.wantsFullscreen {
                    NativeVideoPlayerView(
                        playerManager: viewModel.playerManager,
                        onPlaybackFailure: {
                            if let failedURL = viewModel.currentNativeVideoURL {
                                viewModel.rejectNativeStream(failedURL)
                            }
                        },
                        options: playerOptions
                    )
                } else if let message = viewModel.streamErrorMessage {
                    Color.black
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                        Text(message)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(24)
                } else if viewModel.currentStreamIsProvider {
                    // Provider servers never load a web page; wait for streams.
                    Color.black
                    ProgressView().tint(.white)
                } else if let url = viewModel.currentStreamURL {
                    StreamWebView(
                        url: url,
                        resumePosition: viewModel.playbackResumePosition,
                        onNativeStreamFound: { streamURL, cookies in
                            guard viewModel.currentStreamURL == url else { return }
                            viewModel.adoptNativeStream(streamURL, cookies: cookies)
                        },
                        onProgress: { position, duration, isPlaying in
                            guard viewModel.currentStreamURL == url else { return }
                            viewModel.updateWebPlaybackPosition(position, duration: duration, isPlaying: isPlaying)
                            viewModel.recordPlaybackProgress(position: position, duration: duration)
                        }
                    )
                } else {
                    Color.black
                    ProgressView().tint(.white)
                }
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
    }

    private var playerOptions: PlayerOptions {
        var options = PlayerOptions()
        options.sources = viewModel.nativeSources.enumerated().map {
            PlayerOptions.Choice(id: $0.offset, title: $0.element.name, section: "Source")
        }
        options.selectedSource = viewModel.selectedNativeSourceIndex
        options.sourceLabel = "Source"
        options.onSelectSource = { viewModel.switchNativeSource(to: $0) }
        options.servers = viewModel.store.servers.map(\.name)
        options.selectedServer = viewModel.currentServerIndex
        options.onSelectServer = { viewModel.switchServer(to: $0) }
        if viewModel.selected?.type == .tv {
            options.nextEpisodeLabel = viewModel.nextEpisodeLabel
            options.onNextEpisode = { Task { await viewModel.playNextEpisode() } }
        }
        return options
    }

    /// Custom intro start / end for this show (TV only).
    @ViewBuilder private var introTimes: some View {
        if let item = viewModel.selected, item.type == .tv {
            IntroTimesTable(showKey: "\(item.type.rawValue):\(item.tmdbId)", title: item.title) {
                viewModel.playerManager.reloadIntroOverride()
            }
        }
    }

    // MARK: - Action row

    /// Two Liquid Glass capsule buttons — Reload and Save.
    private var actionRow: some View {
        let isFav = viewModel.selected.map(viewModel.store.isFavorite) == true

        return HStack(spacing: 10) {
            Button {
                viewModel.reloadPlayer()
            } label: {
                Label("Reload", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(CapsuleGlassButtonStyle(fidelity: fidelity))

            Button {
                viewModel.toggleFavoriteOnSelected()
            } label: {
                Label(isFav ? "Saved" : "Save", systemImage: isFav ? "heart.fill" : "heart")
            }
            .buttonStyle(CapsuleGlassButtonStyle(isActive: isFav, fidelity: fidelity))
        }
    }

    // MARK: - Meta chips

    @ViewBuilder
    private var metaLine: some View {
        if let item = viewModel.selected {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(item.typeLabel)
                    if !item.year.isEmpty { chip(item.year) }
                    if let r = item.rating, r > 0 { chip("★ \(String(format: "%.1f", r))") }
                    chip("TMDB \(item.tmdbId)")
                }
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
    }
}

// MARK: - Next Episode button

/// Prominent full-width "Next Episode" row shown above the episode list.
/// Handles season boundary: if we're on the last episode of a season and
/// a next season exists, it shows "Next: S2E1 …" and switches season on tap.
struct NextEpisodeButton: View {
    let label: String
    let onTap: () -> Void

    init(episode: Episode, onTap: @escaping () -> Void) {
        self.label = "S\(episode.seasonNumber ?? 0)E\(episode.episodeNumber) · \(episode.name ?? "Next")"
        self.onTap = onTap
    }

    init(label: String, onTap: @escaping () -> Void) {
        self.label = label
        self.onTap = onTap
    }

    @Environment(\.glassFidelity) private var fidelity

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 2) {
                    Text("NEXT EPISODE")
                        .font(.caption2.weight(.bold))
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.55))
                    Text(label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background { nextEpBackground }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var nextEpBackground: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), fidelity == .full {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .glassEffect(.regular.tint(Color.white.opacity(0.07)).interactive(),
                             in: .rect(cornerRadius: 18))
        } else {
            fallbackBg
        }
        #else
        fallbackBg
        #endif
    }

    private var fallbackBg: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.white.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
    }
}

// MARK: - Server selector

struct ServerSelector: View {
    let names: [String]
    let selectedIndex: Int
    let onSelect: (Int) -> Void
    @Environment(\.glassFidelity) private var fidelity

    init(viewModel: CatalogViewModel) {
        names = viewModel.store.servers.map(\.name)
        selectedIndex = viewModel.currentServerIndex
        onSelect = { viewModel.switchServer(to: $0) }
    }

    init(names: [String], selectedIndex: Int, onSelect: @escaping (Int) -> Void) {
        self.names = names
        self.selectedIndex = selectedIndex
        self.onSelect = onSelect
    }

    var body: some View {
        HStack {
            Text("Server")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                    Button {
                        onSelect(index)
                    } label: {
                        if index == selectedIndex {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            } label: {
                Label(names.indices.contains(selectedIndex) ? names[selectedIndex] : "Select",
                      systemImage: "chevron.up.chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
            }
        }
        .padding(14)
        .background { selectorBackground }
    }

    @ViewBuilder
    private var selectorBackground: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), fidelity == .full {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .glassEffect(.regular.tint(Color.white.opacity(0.06)),
                             in: .rect(cornerRadius: 14))
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        }
        #else
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(0.06))
        #endif
    }
}

// MARK: - Cast row

struct CastRow: View {
    let cast: [CastMember]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cast")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                // Header has the same left indent as the scroll content's first item
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(cast) { actor in
                        Link(destination: actor.tmdbPersonURL) {
                            VStack(spacing: 6) {
                                ZStack {
                                    Circle().fill(Color.white.opacity(0.1))
                                    if let url = actor.profileURL {
                                        AsyncImage(url: url) { phase in
                                            if let image = phase.image {
                                                image.resizable().scaledToFill().clipShape(Circle())
                                            }
                                        }
                                    } else {
                                        Text(actor.initials)
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.white.opacity(0.6))
                                    }
                                }
                                .frame(width: 64, height: 64)
                                .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))

                                Text(actor.name)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(actor.character ?? "")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 80)
                        }
                        .buttonStyle(.plain)
                    }
                }
                // Horizontal padding on the HStack, not the outer container,
                // so the scroll view bleeds edge-to-edge without black clipping.
                .padding(.horizontal, 20)
            }
        }
        // Remove horizontal padding here — the header and HStack each carry
        // their own 20pt indent so nothing clips at the screen edge.
    }
}
