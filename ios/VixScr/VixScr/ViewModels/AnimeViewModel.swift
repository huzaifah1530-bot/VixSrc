import Foundation
import Observation
import SwiftUI

/// State for the Anime tab. The counterpart of `CatalogViewModel`, but the
/// catalogue, search and episodes all come straight from the anime site
/// (AnimeKai by default) — no TMDB.
@MainActor
@Observable
final class AnimeViewModel {
    let store: AppStore

    // MARK: Home + search
    private(set) var homeRows: [MediaRow] = []
    private(set) var hero: MediaItem?
    private(set) var isLoadingHome = false
    private(set) var homeErrorMessage: String?
    private(set) var homeLoaded = false
    private(set) var searchItems: [MediaItem] = []
    private(set) var isSearching = false
    var searchQuery = ""
    private var searchDebounceTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var heroCycleTask: Task<Void, Never>?
    private var heroCycleIndex = 0

    // MARK: Player
    var isPlayerPresented = false
    private(set) var selected: MediaItem?
    private(set) var details: AnimeKaiClient.Details?
    private(set) var isLoadingDetails = false
    private(set) var detailsErrorMessage: String?
    private(set) var selectedEpisode: AnimeKaiClient.EpisodeInfo?
    var episodeQuery = ""
    private(set) var currentServerIndex = 0
    private(set) var nativeSources: [StreamURLExtractor.ResolvedStream] = []
    private(set) var selectedNativeSourceIndex = 0
    private(set) var currentNativeVideoURL: URL?
    private(set) var isResolvingStream = false
    private(set) var statusMessage: String?

    let playerManager = VideoPlayerManager()
    private var rejectedURLs: Set<URL> = []
    private var resolutionTask: Task<Void, Never>?
    private var detailsTask: Task<Void, Never>?
    /// Slugs differ between sites, so each server's slug is looked up once.
    private var slugsByServer: [Int: String] = [:]
    /// Last audio track / quality picked, carried across episodes.
    private var preferredAudio = "Sub"
    private var preferredQuality = "Auto"

    // MARK: Toasts
    var toastMessage: String?
    private var toastTask: Task<Void, Never>?

    init(store: AppStore) {
        self.store = store
    }

    private var catalogBase: String? { store.animeServers.first?.base }

    // MARK: - Rows

    var displayedRows: [MediaRow] {
        if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            return [MediaRow(title: "Search results", subtitle: "From \(store.animeServers.first?.name ?? "anime server")", items: searchItems)]
        }
        var rows = homeRows
        let recents = store.animeRecents
        if !recents.isEmpty {
            rows.insert(MediaRow(title: "Continue watching", subtitle: "Saved on this device", items: recents), at: 0)
        }
        return rows.filter { !$0.items.isEmpty }
    }

    func loadHome() async {
        guard let base = catalogBase else {
            homeRows = []
            hero = nil
            homeErrorMessage = nil
            return
        }
        isLoadingHome = true
        homeErrorMessage = nil
        async let viewed = try? AnimeKaiClient.list(base: base, path: "/most-viewed?page=1")
        async let updated = try? AnimeKaiClient.list(base: base, path: "/filter?sort=latest-updated&page=1")
        async let top = try? AnimeKaiClient.list(base: base, path: "/filter?sort=score&page=1")
        async let added = try? AnimeKaiClient.list(base: base, path: "/filter?sort=latest-added&page=1")
        let (v, u, t, a) = await (viewed, updated, top, added)

        homeRows = [
            MediaRow(title: "Most viewed", subtitle: "Popular on \(store.animeServers.first?.name ?? "AnimeKai")", items: (v ?? []).map { MediaItem.anime($0) }),
            MediaRow(title: "New episodes", subtitle: "Latest updated", items: (u ?? []).map { MediaItem.anime($0) }),
            MediaRow(title: "Top rated", subtitle: "Highest scores", items: (t ?? []).map { MediaItem.anime($0) }),
            MediaRow(title: "Newly added", subtitle: "Just arrived", items: (a ?? []).map { MediaItem.anime($0) }),
        ].filter { !$0.items.isEmpty }

        if homeRows.isEmpty {
            homeErrorMessage = "Couldn't reach \(store.animeServers.first?.name ?? "the anime server"). Check your connection or try another anime server in Settings."
        } else {
            homeLoaded = true
            if hero == nil, let first = homeRows.first?.items.first {
                hero = first
                hero = await withSynopsis(first)
            }
            startHeroCycle()
        }
        isLoadingHome = false
    }

    private func startHeroCycle() {
        heroCycleTask?.cancel()
        heroCycleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard !self.isPlayerPresented, self.searchQuery.isEmpty else { continue }
                let items = self.homeRows.first?.items ?? []
                guard items.count > 1 else { continue }
                self.heroCycleIndex = (self.heroCycleIndex + 1) % items.count
                let next = await self.withSynopsis(items[self.heroCycleIndex])
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.8)) { self.hero = next }
            }
        }
    }

    /// List cards carry no synopsis, so the hero fetches it (cached by slug).
    private var synopsisCache: [String: String] = [:]

    private func withSynopsis(_ item: MediaItem) async -> MediaItem {
        guard let slug = item.animeSlug, let base = catalogBase else { return item }
        var copy = item
        if let cached = synopsisCache[slug] {
            copy.description = cached
            return copy
        }
        if let details = try? await AnimeKaiClient.details(base: base, slug: slug), !details.description.isEmpty {
            synopsisCache[slug] = details.description
            copy.description = details.description
        }
        return copy
    }

    // MARK: - Search

    func debounceSearch(_ value: String) {
        searchQuery = value
        searchDebounceTask?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            isSearching = false
            searchItems = []
            return
        }
        isSearching = true
        searchDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await self?.runSearch(trimmed)
        }
    }

    private func runSearch(_ query: String) async {
        guard let base = catalogBase else { isSearching = false; return }
        searchGeneration += 1
        let generation = searchGeneration
        let results = (try? await AnimeKaiClient.search(base: base, query: query)) ?? []
        guard generation == searchGeneration else { return }
        isSearching = false
        searchItems = results.map { MediaItem.anime($0) }
        if !searchItems.isEmpty { store.addAnimeSearchHistory(query) }
    }

    // MARK: - Opening a show

    func open(_ item: MediaItem) {
        guard let slug = item.animeSlug else { return }
        heroCycleTask?.cancel()
        selected = item
        details = nil
        detailsErrorMessage = nil
        selectedEpisode = nil
        episodeQuery = ""
        currentServerIndex = 0
        slugsByServer = [0: slug]
        resumeIntent = true
        resetPlayback()
        playerManager.setNowPlayingMetadata(title: item.title, subtitle: nil, artworkURL: item.posterURL)
        isPlayerPresented = true
        loadDetails(resumeEpisode: item.resumeEpisode)
    }

    private func loadDetails(resumeEpisode: Int?) {
        guard let server = currentServer, let slug = slugsByServer[currentServerIndex] else { return }
        let index = currentServerIndex
        isLoadingDetails = true
        detailsErrorMessage = nil
        detailsTask?.cancel()
        detailsTask = Task { @MainActor [weak self] in
            do {
                let details = try await AnimeKaiClient.details(base: server.base, slug: slug)
                guard let self, !Task.isCancelled, self.currentServerIndex == index else { return }
                self.details = details
                self.isLoadingDetails = false
                // Fill in the description and poster the list card lacked.
                if var item = self.selected {
                    if !details.description.isEmpty { item.description = details.description }
                    if item.posterPath?.isEmpty != false { item.posterPath = details.show.posterURL; item.backdropPath = details.show.posterURL }
                    self.selected = item
                }
                let target = details.episodes.first { $0.intNumber == resumeEpisode } ?? details.episodes.first
                if let target { self.selectEpisode(target) }
                else { self.statusMessage = "No episodes yet" }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isLoadingDetails = false
                self.detailsErrorMessage = error.localizedDescription
                self.statusMessage = error.localizedDescription
            }
        }
    }

    var filteredEpisodes: [AnimeKaiClient.EpisodeInfo] {
        let episodes = details?.episodes ?? []
        let query = episodeQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return episodes }
        return episodes.filter { $0.number == query || $0.title.lowercased().contains(query) }
    }

    var nextEpisode: AnimeKaiClient.EpisodeInfo? {
        guard let current = selectedEpisode, let episodes = details?.episodes,
              let index = episodes.firstIndex(of: current), index + 1 < episodes.count else { return nil }
        return episodes[index + 1]
    }

    // MARK: - Episodes and servers

    var currentServer: AnimeServer? {
        store.animeServers.indices.contains(currentServerIndex) ? store.animeServers[currentServerIndex] : nil
    }

    func selectEpisode(_ episode: AnimeKaiClient.EpisodeInfo) {
        guard let item = selected, let server = currentServer else { return }
        selectedEpisode = episode
        PartySession.shared.localMediaChanged()
        store.addRecent(item, season: 1, episode: episode.intNumber, episodeTitle: episode.title == "Episode \(episode.number)" ? nil : episode.title)
        playerManager.setNowPlayingMetadata(title: item.title, subtitle: nowPlayingSubtitle, artworkURL: item.posterURL)
        resetPlayback()
        if DeviceLink.shared.routesPlayback {
            // The computer looks the show up in its own anime catalogue.
            let slug = slugsByServer[0] ?? item.animeSlug ?? ""
            var extra: [String: Any] = ["slug": slug, "episode": episode.number, "server": server.name]
            if resumeIntent { extra["resume"] = true }
            resumeIntent = false
            DeviceLink.shared.playOnDesktop("play-anime", item: item, extra: extra)
            return
        }
        resumeIntent = false
        isResolvingStream = true
        statusMessage = "Loading episode \(episode.number)…"
        let progressKey = currentProgressID
        resolutionTask = Task { @MainActor [weak self] in
            do {
                let streams = try await AnimeKaiClient.streams(base: server.base, episodeIds: episode.ids)
                guard let self, !Task.isCancelled, self.currentProgressID == progressKey else { return }
                self.isResolvingStream = false
                self.statusMessage = nil
                self.nativeSources = streams
                let index = streams.firstIndex { $0.audio == self.preferredAudio && $0.quality == self.preferredQuality }
                    ?? streams.firstIndex { $0.audio == self.preferredAudio }
                    ?? 0
                self.selectedNativeSourceIndex = index
                self.loadSource(at: index)
            } catch {
                guard let self, !Task.isCancelled, self.currentProgressID == progressKey else { return }
                self.isResolvingStream = false
                self.statusMessage = "\(server.name): \(error.localizedDescription)"
            }
        }
    }

    /// Switches site. The same show is looked up there by title, then the
    /// same episode number is played.
    func switchServer(to index: Int) {
        guard store.animeServers.indices.contains(index), index != currentServerIndex, let item = selected else { return }
        if DeviceLink.shared.routesPlayback {
            // The computer finds the show on the other site itself.
            currentServerIndex = index
            DeviceLink.shared.command("server", ["name": store.animeServers[index].name, "index": index])
            return
        }
        let resume = selectedEpisode?.intNumber
        currentServerIndex = index
        details = nil
        selectedEpisode = nil
        resetPlayback()
        let server = store.animeServers[index]
        showToast("Switched to \(server.name)")
        if slugsByServer[index] != nil {
            loadDetails(resumeEpisode: resume)
            return
        }
        isLoadingDetails = true
        statusMessage = "Finding on \(server.name)…"
        detailsTask?.cancel()
        detailsTask = Task { @MainActor [weak self] in
            let slug = try? await AnimeKaiClient.findSlug(base: server.base, title: item.title)
            guard let self, !Task.isCancelled, self.currentServerIndex == index else { return }
            guard let slug else {
                self.isLoadingDetails = false
                self.detailsErrorMessage = "Couldn't find this title on \(server.name)"
                self.statusMessage = self.detailsErrorMessage
                return
            }
            self.slugsByServer[index] = slug
            self.loadDetails(resumeEpisode: resume)
        }
    }

    func switchSource(to index: Int) {
        guard nativeSources.indices.contains(index) else { return }
        // Sub ↔ Dub / quality is personal: reload without holding the party.
        PartySession.shared.personalReload()
        selectedNativeSourceIndex = index
        if let audio = nativeSources[index].audio { preferredAudio = audio }
        if let quality = nativeSources[index].quality { preferredQuality = quality }
        loadSource(at: index)
    }

    private func loadSource(at index: Int) {
        guard nativeSources.indices.contains(index) else { return }
        let source = nativeSources[index]
        playerManager.cleanup()
        currentNativeVideoURL = source.url
        let progressID = currentProgressID
        playerManager.onProgressUpdate = { [weak self] position, duration in
            self?.recordProgress(position: position, duration: duration, id: progressID)
        }
        playerManager.load(
            url: source.url,
            requestHeaders: source.requestHeaders,
            startPosition: resumePosition,
            progressId: progressID,
            mediaTitle: selected?.title,
            subtitle: nowPlayingSubtitle,
            artworkURL: selected?.posterURL
        )
        // Soft subs switch on by default for the subtitled track only.
        playerManager.setExternalSubtitles(source.subtitles, autoSelect: source.audio == "Sub")

        // Intro: the stream's own timestamps win; otherwise AniSkip via a
        // MAL id verified from the watch page (never a title guess).
        let store = store
        playerManager.autoSkipEnabled = { store.autoSkipIntro }
        var fetch: (@Sendable (Double) async -> [SkipSegment])?
        if let identity = details?.identity, let episode = selectedEpisode?.number {
            fetch = { duration in
                await IntroSkipService.shared.anime(identity: identity, episode: episode, duration: duration)
            }
        }
        playerManager.configureIntroSkip(episodeKey: progressID, streamSegments: source.segments, fetch: fetch)
    }

    /// A source failed in AVPlayer: try the next one (same audio first).
    func rejectCurrentSource() {
        guard let url = currentNativeVideoURL else { return }
        rejectedURLs.insert(url)
        let audio = nativeSources.indices.contains(selectedNativeSourceIndex) ? nativeSources[selectedNativeSourceIndex].audio : nil
        let untried = nativeSources.indices.filter { !rejectedURLs.contains(nativeSources[$0].url) }
        if let next = untried.first(where: { nativeSources[$0].audio == audio }) ?? untried.first {
            selectedNativeSourceIndex = next
            loadSource(at: next)
        } else {
            playerManager.cleanup()
            currentNativeVideoURL = nil
            statusMessage = "None of the streams would play. Try another server."
        }
    }

    /// True from `open()` until the first playback request goes out.
    private var resumeIntent = false

    /// The computer is on a different episode of this show: match it here
    /// without sending another play command.
    func followRemote(_ state: RemoteState) {
        guard let item = selected, state.open, state.itemKey == "\(item.type.rawValue):\(item.tmdbId)",
              let number = state.animeEpisode, selectedEpisode?.number != number,
              let ep = details?.episodes.first(where: { $0.number == number }) else { return }
        selectedEpisode = ep
    }

    /// Re-runs the current episode on whichever device is now the target.
    func replayOnCurrentTarget() {
        if let episode = selectedEpisode { selectEpisode(episode) }
    }

    func reload() {
        if let episode = selectedEpisode { selectEpisode(episode) } else { loadDetails(resumeEpisode: nil) }
    }

    private func resetPlayback() {
        resolutionTask?.cancel()
        rejectedURLs.removeAll()
        nativeSources = []
        selectedNativeSourceIndex = 0
        currentNativeVideoURL = nil
        isResolvingStream = false
        statusMessage = nil
        playerManager.cleanup()
    }

    func closePlayer() {
        PartySession.shared.detach(self)
        playerManager.wantsFullscreen = false
        isPlayerPresented = false
        detailsTask?.cancel()
        resetPlayback()
        startHeroCycle()
    }

    // MARK: - Progress

    /// Matches the `tv:<id>:<season>:<episode>` keys `AppStore` already
    /// reads, so cards show progress bars with no extra code.
    private var currentProgressID: String {
        guard let item = selected else { return "anime:unknown" }
        return "tv:\(item.tmdbId):1:\(selectedEpisode?.intNumber ?? 0)"
    }

    private var resumePosition: Double {
        guard let progress = store.progress(for: currentProgressID),
              progress.position > 0, progress.progress < 0.95 else { return 0 }
        return progress.position
    }

    private func recordProgress(position: Double, duration: Double, id: String) {
        guard position.isFinite, duration.isFinite, position >= 0, duration > 0 else { return }
        store.saveProgress(WatchProgress(id: id, position: position, duration: duration,
                                         lastWatchedAt: Date(), completed: position / duration >= 0.95))
    }

    private var nowPlayingSubtitle: String? {
        guard let episode = selectedEpisode else { return nil }
        return episode.title == "Episode \(episode.number)" ? "Episode \(episode.number)" : "E\(episode.number) — \(episode.title)"
    }

    // MARK: - Misc

    func toggleFavoriteOnSelected() {
        guard let selected else { return }
        store.toggleFavorite(selected)
        showToast(store.isFavorite(selected) ? "Added to favourites" : "Removed from favourites")
    }

    func toggleFavoriteOnHero() {
        guard let hero else { return }
        store.toggleFavorite(hero)
        showToast(store.isFavorite(hero) ? "Added to favourites" : "Removed from favourites")
    }

    func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_550_000_000)
            guard !Task.isCancelled else { return }
            self?.toastMessage = nil
        }
    }
}
