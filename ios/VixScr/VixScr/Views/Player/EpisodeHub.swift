import SwiftUI

/// Mirrors `#episodeHub` — season chips, an episode search field, and the
/// scrolling list of episode rows.
struct EpisodeHub: View {
    @Bindable var viewModel: CatalogViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("EPISODES")
                        .font(.system(size: 11, weight: .black))
                        .tracking(2)
                        .foregroundStyle(.white.opacity(0.45))
                    Text("Modern Season Hub")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(.white)
                }
                Spacer()
                Image(systemName: "list.bullet")
                    .foregroundStyle(.white.opacity(0.55))
            }

            if let details = viewModel.tvDetails {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(details.usableSeasons) { season in
                            let isActive = viewModel.selectedSeason?.seasonNumber == season.seasonNumber
                            Button("Season \(season.seasonNumber)") {
                                Task { await viewModel.selectSeason(season.seasonNumber) }
                            }
                            .font(.system(size: 13, weight: .black))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .foregroundStyle(isActive ? .black : .white)
                            .background(isActive ? Color.white : Color.white.opacity(0.1), in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(isActive ? 0 : 0.2), lineWidth: 1))
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.45))
                TextField("", text: $viewModel.episodeQuery, prompt: Text("Find episode in this season...").foregroundStyle(.white.opacity(0.35)))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.2), lineWidth: 1))

            if viewModel.isLoadingEpisodes {
                Text("Loading episodes...")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else if let error = viewModel.episodeErrorMessage {
                Text(error)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else if viewModel.filteredEpisodes.isEmpty {
                Text("No episodes match that search.")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
        .padding(16)
        .vixGlass(.regular, cornerRadius: 28)
    }
}

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
                        Text("EPISODE \(episode.episodeNumber)")
                            .font(.system(size: 10, weight: .black))
                            .tracking(1)
                            .foregroundStyle(isActive ? .black.opacity(0.55) : .white.opacity(0.45))
                        Spacer()
                        if let runtime = episode.runtime {
                            Text("\(runtime)m")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(isActive ? .black.opacity(0.6) : .white.opacity(0.55))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background((isActive ? Color.black.opacity(0.06) : Color.white.opacity(0.1)), in: Capsule())
                        }
                    }
                    Text(episode.name ?? "Untitled episode")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(isActive ? .black : .white)
                        .lineLimit(1)
                    Text(episode.overview ?? "No episode overview from TMDB.")
                        .font(.system(size: 12))
                        .foregroundStyle(isActive ? .black.opacity(0.55) : .white.opacity(0.5))
                        .lineLimit(2)
                }
            }
            .padding(10)
            .background(isActive ? Color.white : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(isActive ? Color.white : Color.white.opacity(0.16), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var stillImage: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.1))
            .frame(width: 96, height: 64)
            .overlay {
                if let url = episode.stillURL {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                } else {
                    Text("NO STILL")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
    }
}
