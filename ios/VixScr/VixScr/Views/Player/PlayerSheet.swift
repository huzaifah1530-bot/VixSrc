import SwiftUI

/// Mirrors `#playerModal` — the full streaming sheet: player frame, server
/// selector, action buttons, cast row, and (for TV) the season/episode hub.
struct PlayerSheet: View {
    @Bindable var viewModel: CatalogViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    playerFrame

                    if viewModel.store.servers.count > 1 {
                        ServerSelector(viewModel: viewModel)
                    }

                    actionRow

                    if let description = viewModel.selected?.description {
                        Text(description)
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(4)
                    }

                    metaLine

                    if !viewModel.cast.isEmpty {
                        CastRow(cast: viewModel.cast)
                    }

                    if viewModel.selected?.type == .tv {
                        EpisodeHub(viewModel: viewModel)
                    }
                }
                .padding(20)
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
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

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
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.2), lineWidth: 1))
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            actionButton("Reload", icon: "arrow.counterclockwise") { viewModel.reloadPlayer() }
            actionButton("Copy URL", icon: "doc.on.doc") {
                if let url = viewModel.currentStreamURL {
                    UIPasteboard.general.string = url.absoluteString
                    viewModel.showToast("Embed URL copied")
                }
            }
            actionButton(
                viewModel.selected.map(viewModel.store.isFavorite) == true ? "Favourited" : "Favourite",
                icon: viewModel.selected.map(viewModel.store.isFavorite) == true ? "heart.fill" : "heart"
            ) {
                viewModel.toggleFavoriteOnSelected()
            }
        }
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .black))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
        .vixGlass(.regular, cornerRadius: 18)
    }

    @ViewBuilder
    private var metaLine: some View {
        if let item = viewModel.selected {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(item.typeLabel)
                    if !item.year.isEmpty { chip(item.year) }
                    if let rating = item.rating, rating > 0 { chip("\u{2605} \(String(format: "%.1f", rating))") }
                    chip("TMDB \(item.tmdbId)")
                }
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white.opacity(0.58))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
    }
}

struct ServerSelector: View {
    @Bindable var viewModel: CatalogViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("STREAMING SERVER")
                .font(.system(size: 11, weight: .black))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.45))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(viewModel.store.servers.enumerated()), id: \.offset) { index, server in
                        let isActive = index == viewModel.currentServerIndex
                        Button(server.name) { viewModel.switchServer(to: index) }
                            .font(.system(size: 12, weight: .black))
                            .tracking(0.5)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .foregroundStyle(isActive ? .black : .white)
                            .background(isActive ? Color.white : Color.white.opacity(0.1), in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(isActive ? 0 : 0.2), lineWidth: 1))
                    }
                }
            }
        }
        .padding(16)
        .vixGlass(.regular, cornerRadius: 24)
    }
}

struct CastRow: View {
    let cast: [CastMember]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CAST")
                .font(.system(size: 11, weight: .black))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.45))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(cast) { actor in
                        Link(destination: URL(string: "https://www.themoviedb.org/person/\(actor.id)")!) {
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
                                            .font(.system(size: 13, weight: .black))
                                            .foregroundStyle(.white.opacity(0.6))
                                    }
                                }
                                .frame(width: 64, height: 64)
                                .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))

                                Text(actor.name)
                                    .font(.system(size: 11, weight: .black))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(actor.character ?? "")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .lineLimit(1)
                            }
                            .frame(width: 80)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .vixGlass(.regular, cornerRadius: 24)
    }
}
