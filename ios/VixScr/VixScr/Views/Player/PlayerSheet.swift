import SwiftUI

struct PlayerSheet: View {
    @Bindable var viewModel: CatalogViewModel
    @Environment(\.glassFidelity) private var fidelity
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.verticalSizeClass) private var vSizeClass

    private var isLandscape: Bool { hSizeClass == .compact && vSizeClass == .compact }

    var body: some View {
        NavigationStack {
            Group {
                if isLandscape {
                    landscapeLayout
                } else {
                    portraitLayout
                }
            }
            .background(VixTheme.background.ignoresSafeArea())
            .navigationTitle(viewModel.selected?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
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
        .preferredColorScheme(.dark)
    }

    // MARK: - Portrait layout (original)

    private var portraitLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                playerFrame
                nextEpisodeButton
                serverSelectorView
                actionRow
                descriptionView
                metaLine
                castSection
                episodeSection
            }
            .padding(20)
        }
    }

    // MARK: - Landscape split layout
    // Left 55%: player + next episode button (everything you need to control playback)
    // Right 45%: scrollable info — server, actions, description, cast, episodes

    private var landscapeLayout: some View {
        GeometryReader { geo in
            HStack(alignment: .top, spacing: 0) {
                // LEFT: player + immediate controls
                VStack(spacing: 12) {
                    playerFrame
                    nextEpisodeButton
                    serverSelectorView
                    actionRow
                    Spacer()
                }
                .padding(16)
                .frame(width: geo.size.width * 0.55)

                Divider().background(Color.white.opacity(0.1))

                // RIGHT: info panel
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        descriptionView
                        metaLine
                        castSection
                        episodeSection
                    }
                    .padding(16)
                }
                .frame(width: geo.size.width * 0.45)
            }
        }
    }

    // MARK: - Subviews (shared between portrait and landscape)

    @ViewBuilder private var nextEpisodeButton: some View {
        if viewModel.selected?.type == .tv, let next = viewModel.nextEpisode {
            NextEpisodeButton(episode: next) {
                Task { await viewModel.selectEpisode(next) }
            }
        }
    }

    @ViewBuilder private var serverSelectorView: some View {
        if viewModel.store.servers.count > 1 {
            ServerSelector(viewModel: viewModel)
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
            if let url = viewModel.currentStreamURL {
                StreamWebView(url: url)
            } else {
                Color.black
                ProgressView().tint(.white)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
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
    let episode: Episode
    let onTap: () -> Void

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
                    Text("S\(episode.seasonNumber ?? 0)E\(episode.episodeNumber) · \(episode.name ?? "Next")")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.45))
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
    @Bindable var viewModel: CatalogViewModel
    @Environment(\.glassFidelity) private var fidelity

    var body: some View {
        HStack {
            Text("Server")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(Array(viewModel.store.servers.enumerated()), id: \.offset) { index, server in
                    Button {
                        viewModel.switchServer(to: index)
                    } label: {
                        if index == viewModel.currentServerIndex {
                            Label(server.name, systemImage: "checkmark")
                        } else {
                            Text(server.name)
                        }
                    }
                }
            } label: {
                let name = viewModel.store.servers.indices.contains(viewModel.currentServerIndex)
                    ? viewModel.store.servers[viewModel.currentServerIndex].name : "Select"
                Label(name, systemImage: "chevron.up.chevron.down")
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
            }
        }
    }
}
