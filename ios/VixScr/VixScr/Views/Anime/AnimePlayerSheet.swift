import SwiftUI

/// Player for the Anime tab. Same layout and styling as `PlayerSheet`, with
/// anime servers, a Sub / Dub quality picker and the site's episode list.
struct AnimePlayerSheet: View {
    @Bindable var viewModel: AnimeViewModel
    @Environment(\.glassFidelity) private var fidelity

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    playerFrame
                    if let next = viewModel.nextEpisode {
                        NextEpisodeButton(label: "E\(next.number) · \(next.title)") {
                            viewModel.selectEpisode(next)
                        }
                    }
                    if viewModel.store.animeServers.count > 1 {
                        ServerSelector(
                            names: viewModel.store.animeServers.map(\.name),
                            selectedIndex: viewModel.currentServerIndex,
                            onSelect: { viewModel.switchServer(to: $0) }
                        )
                    }
                    if DeviceLink.shared.routesPlayback {
                        RemoteOptionsView()
                    } else {
                        qualitySelector
                    }
                    actionRow
                    if let item = viewModel.selected {
                        Text(item.description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                    metaLine
                    episodeSection
                }
                .padding(20)
            }
            .background(VixTheme.background.ignoresSafeArea())
            .navigationTitle(viewModel.selected?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 8) {
                        PlaybackTargetMenu { viewModel.replayOnCurrentTarget() }
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
                    .buttonStyle(CircleGlassButtonStyle(fidelity: fidelity))
                    .accessibilityLabel("Close")
                }
            }
        }
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
        .onChange(of: DeviceLink.shared.remote) { _, state in
            guard DeviceLink.shared.routesPlayback, DeviceLink.shared.shouldFollowRemote, let state else { return }
            viewModel.followRemote(state)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Player

    private var playerFrame: some View {
        ZStack {
            if DeviceLink.shared.routesPlayback {
                RemotePlayerView(poster: viewModel.selected?.posterURL) { viewModel.replayOnCurrentTarget() }
            } else if viewModel.currentNativeVideoURL != nil || viewModel.playerManager.wantsFullscreen {
                NativeVideoPlayerView(
                    playerManager: viewModel.playerManager,
                    onPlaybackFailure: { viewModel.rejectCurrentSource() },
                    options: playerOptions
                )
            } else {
                Color.black
                VStack(spacing: 10) {
                    if viewModel.isResolvingStream || viewModel.isLoadingDetails || viewModel.statusMessage == nil {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title2)
                            .foregroundStyle(.yellow)
                    }
                    if let status = viewModel.statusMessage {
                        Text(status)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
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
            PlayerOptions.Choice(id: $0.offset, title: $0.element.quality ?? $0.element.name,
                                 section: $0.element.audio == "Dub" ? "Dubbed" : "Subtitled")
        }
        options.selectedSource = viewModel.selectedNativeSourceIndex
        options.onSelectSource = { viewModel.switchSource(to: $0) }
        options.servers = viewModel.store.animeServers.map(\.name)
        options.selectedServer = viewModel.currentServerIndex
        options.onSelectServer = { viewModel.switchServer(to: $0) }
        if let next = viewModel.nextEpisode {
            options.nextEpisodeLabel = "E\(next.number)"
            options.onNextEpisode = { viewModel.selectEpisode(next) }
        }
        return options
    }

    // MARK: - Quality (Sub / Dub)

    @ViewBuilder private var qualitySelector: some View {
        if !viewModel.nativeSources.isEmpty {
            HStack {
                Label("Quality", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    // Grouped by audio so the viewer can hop between e.g.
                    // 1080p Sub and 1080p Dub.
                    ForEach(["Sub", "Dub"], id: \.self) { audio in
                        let entries = Array(viewModel.nativeSources.enumerated()).filter { $0.element.audio == audio }
                        if !entries.isEmpty {
                            Section(audio == "Sub" ? "Subtitled" : "Dubbed") {
                                ForEach(entries, id: \.offset) { index, source in
                                    Button {
                                        viewModel.switchSource(to: index)
                                    } label: {
                                        if index == viewModel.selectedNativeSourceIndex {
                                            Label(source.quality ?? source.name, systemImage: "checkmark")
                                        } else {
                                            Text(source.quality ?? source.name)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Label(viewModel.nativeSources.indices.contains(viewModel.selectedNativeSourceIndex)
                          ? viewModel.nativeSources[viewModel.selectedNativeSourceIndex].name : "Select",
                          systemImage: "chevron.up.chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.blue)
                }
            }
            .padding(14)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // MARK: - Actions + meta

    private var actionRow: some View {
        let isFav = viewModel.selected.map(viewModel.store.isFavorite) == true
        return HStack(spacing: 10) {
            Button { viewModel.reload() } label: {
                Label("Reload", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(CapsuleGlassButtonStyle(fidelity: fidelity))

            Button { viewModel.toggleFavoriteOnSelected() } label: {
                Label(isFav ? "Saved" : "Save", systemImage: isFav ? "heart.fill" : "heart")
            }
            .buttonStyle(CapsuleGlassButtonStyle(isActive: isFav, fidelity: fidelity))
        }
    }

    @ViewBuilder private var metaLine: some View {
        if let details = viewModel.details {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("Anime")
                    if !details.show.kind.isEmpty { chip(details.show.kind) }
                    chip("\(details.episodes.count) episodes")
                    if let sub = details.show.subCount, sub > 0 { chip("Sub \(sub)") }
                    if let dub = details.show.dubCount, dub > 0 { chip("Dub \(dub)") }
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

    // MARK: - Episodes

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Episodes")
                .font(.title3.weight(.bold))

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find episode by number or title", text: $viewModel.episodeQuery)
                    .font(.subheadline)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if viewModel.isLoadingDetails {
                HStack { Spacer(); ProgressView("Loading episodes").tint(.white); Spacer() }
                    .padding(.vertical, 20)
            } else if let error = viewModel.detailsErrorMessage {
                ContentUnavailableView("Couldn't load episodes", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if viewModel.filteredEpisodes.isEmpty {
                ContentUnavailableView.search
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(viewModel.filteredEpisodes) { episode in
                        AnimeEpisodeRow(
                            episode: episode,
                            isActive: viewModel.selectedEpisode?.number == episode.number,
                            progress: viewModel.selected.flatMap {
                                viewModel.store.progress(for: "tv:\($0.tmdbId):1:\(episode.intNumber)")?.progress
                            }
                        ) {
                            viewModel.selectEpisode(episode)
                        }
                    }
                }
            }
        }
    }
}

private struct AnimeEpisodeRow: View {
    let episode: AnimeKaiClient.EpisodeInfo
    let isActive: Bool
    let progress: Double?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Text(episode.number)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(isActive ? .black : .primary)
                    .frame(width: 52, height: 52)
                    .background(isActive ? Color.black.opacity(0.08) : Color.white.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(episode.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isActive ? .black : .primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if episode.hasSub { tag("SUB") }
                        if episode.hasDub { tag("DUB") }
                    }
                    if let progress, progress > 0 {
                        ProgressOverlay(progress: progress)
                            .frame(height: 3)
                            .clipShape(Capsule())
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(isActive ? Color.white : Color.white.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Episode \(episode.number), \(episode.title)")
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(isActive ? Color.black.opacity(0.6) : .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(isActive ? Color.black.opacity(0.08) : Color.white.opacity(0.1), in: Capsule())
    }
}
