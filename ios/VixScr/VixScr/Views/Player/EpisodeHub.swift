import SwiftUI

/// Season picker + episode search + episode list.
struct EpisodeHub: View {
    @Bindable var viewModel: CatalogViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header row: "Episodes" title + season picker
            HStack {
                Text("Episodes")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                Spacer()
                if let details = viewModel.tvDetails,
                   let selectedSeason = viewModel.selectedSeason {
                    Menu {
                        ForEach(details.usableSeasons) { season in
                            Button {
                                Task { await viewModel.selectSeason(season.seasonNumber) }
                            } label: {
                                if season.seasonNumber == selectedSeason.seasonNumber {
                                    Label("Season \(season.seasonNumber)", systemImage: "checkmark")
                                } else {
                                    Text("Season \(season.seasonNumber)")
                                }
                            }
                        }
                    } label: {
                        Label("Season \(selectedSeason.seasonNumber)", systemImage: "chevron.up.chevron.down")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.blue)
                    }
                }
            }

            // Episode search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find episode in this season", text: $viewModel.episodeQuery)
                    .font(.subheadline)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color.white.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            // Episode list
            if viewModel.isLoadingEpisodes {
                HStack { Spacer(); ProgressView("Loading episodes").tint(.white); Spacer() }
                    .padding(.vertical, 20)
            } else if let error = viewModel.episodeErrorMessage {
                ContentUnavailableView(
                    "Couldn't load episodes",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if viewModel.filteredEpisodes.isEmpty {
                ContentUnavailableView.search
            } else {
                VStack(spacing: 10) {
                    ForEach(viewModel.filteredEpisodes) { episode in
                        EpisodeRow(
                            episode: episode,
                            isActive: viewModel.selectedEpisode?.episodeNumber == episode.episodeNumber
                        ) {
                            Task { await viewModel.selectEpisode(episode) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Episode row

private struct EpisodeRow: View {
    let episode: Episode
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                // Thumbnail — wider, no clipping
                stillImage

                // Text — episode number + runtime on one line, title large, no description
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("E\(episode.episodeNumber)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isActive ? Color.black.opacity(0.55) : .secondary)
                        Spacer()
                        if let runtime = episode.runtime {
                            Text("\(runtime)m")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(isActive ? Color.black.opacity(0.55) : .secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    (isActive ? Color.black.opacity(0.08) : Color.white.opacity(0.1)),
                                    in: Capsule()
                                )
                        }
                    }

                    Text(episode.name ?? "Untitled")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isActive ? .black : .primary)
                        .lineLimit(1)

                    // One line only — no one reads the full synopsis in a list
                    if let overview = episode.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.caption)
                            .foregroundStyle(isActive ? Color.black.opacity(0.55) : .secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                isActive ? Color.white : Color.white.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var stillImage: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.1))
            .frame(width: 108, height: 72)
            .overlay {
                if let url = episode.stillURL {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable()
                                .scaledToFill()
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.tertiary)
                }
            }
            // Clip the container so nothing bleeds outside the rounded rect
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
