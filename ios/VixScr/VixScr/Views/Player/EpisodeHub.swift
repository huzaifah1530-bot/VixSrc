import SwiftUI

/// Season picker (native `Menu`), an episode search field, and the list of
/// episode rows for the selected season.
struct EpisodeHub: View {
    @Bindable var viewModel: CatalogViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Episodes")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                Spacer()
                if let details = viewModel.tvDetails, let selectedSeason = viewModel.selectedSeason {
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
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find episode in this season", text: $viewModel.episodeQuery)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if viewModel.isLoadingEpisodes {
                HStack {
                    Spacer()
                    ProgressView("Loading episodes")
                    Spacer()
                }
                .padding(.vertical, 20)
            } else if let error = viewModel.episodeErrorMessage {
                ContentUnavailableView("Couldn't load episodes", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if viewModel.filteredEpisodes.isEmpty {
                ContentUnavailableView.search
            } else {
                VStack(spacing: 8) {
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

/// Mirrors `#episodeHub`'s individual episode rows.
private struct EpisodeRow: View {
    let episode: Episode
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                stillImage
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Episode \(episode.episodeNumber)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(isActive ? .black.opacity(0.6) : .secondary)
                        Spacer()
                        if let runtime = episode.runtime {
                            Text("\(runtime)m")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(isActive ? .black.opacity(0.6) : .secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background((isActive ? Color.black.opacity(0.08) : Color.white.opacity(0.1)), in: Capsule())
                        }
                    }
                    Text(episode.name ?? "Untitled episode")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isActive ? .black : .primary)
                        .lineLimit(1)
                    Text(episode.overview ?? "No episode overview from TMDB.")
                        .font(.footnote)
                        .foregroundStyle(isActive ? .black.opacity(0.6) : .secondary)
                        .lineLimit(2)
                }
            }
            .padding(10)
            .background(isActive ? Color.white : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var stillImage: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.1))
            .frame(width: 96, height: 64)
            .overlay {
                if let url = episode.stillURL {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.tertiary)
                }
            }
    }
}
