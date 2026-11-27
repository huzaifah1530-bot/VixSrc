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
        // A party viewer opening their own pick leaves the party: ask first.
        // Room-driven opens (loadPartyMedia) never ask, so they stay synchronous.
        let key = item.resumeEpisode.map { "anime:\(slug):\($0)" }
        guard PartySession.shared.wouldLeave(mediaKey: key) else { performOpen(item, slug: slug); return }
        Task { @MainActor [weak self] in
            guard await PartySession.shared.confirmLeave("Opening \(item.title)", mediaKey: key) else { return }
            self?.performOpen(item, slug: slug)
        }
    }

    private func performOpen(_ item: MediaItem, slug: String) {
        // The new title replaces whatever the mini player was showing.
        MiniPlayerCenter.shared.release(playerManager)
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

    /// `confirmFallback`: after a server switch, playing a different episode
    /// than the one asked for would leave a party, so ask first.
    private func loadDetails(resumeEpisode: Int?, confirmFallback: Bool = false) {
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
                let exact = details.episodes.first { $0.intNumber == resumeEpisode }
                guard let target = exact ?? details.episodes.first else {
                    self.statusMessage = "No episodes yet"
                    return
                }
                if confirmFallback, exact == nil, let resumeEpisode {
                    let proceed = await PartySession.shared.confirmLeave(
                        "\(server.name) doesn't have episode \(resumeEpisode). Playing episode \(target.number)",
                        mediaKey: self.partyKey(for: target))
                    guard !Task.isCancelled, self.currentServerIndex == index else { return }
                    guard proceed else {
                        self.statusMessage = "Episode \(resumeEpisode) isn't on \(server.name)"
                        return
                    }
                }
                self.selectEpisode(target)
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
                // The show's default Sub / Dub (Anime Settings) wins over the
                // last one picked.
                let audio = self.titleAudioPreference ?? self.preferredAudio
                let index = streams.firstIndex { $0.audio == audio && $0.quality == self.preferredQuality }
                    ?? streams.firstIndex { $0.audio == audio }
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
        // The same episode keeps the party key (it comes from the show, not
        // the server), so only a fallback to another episode needs asking.
        if slugsByServer[index] != nil {
            loadDetails(resumeEpisode: resume, confirmFallback: true)
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
            self.loadDetails(resumeEpisode: resume, confirmFallback: true)
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
        playerManager.loadIntroOverride = { store.introOverrides[$0] }
        var fetch: (@Sendable (Double) async -> [SkipSegment])?
        if let identity = details?.identity, let episode = selectedEpisode?.number {
            let credential = store.credential
            fetch = { duration in
                await IntroSkipService.shared.anime(identity: identity, episode: episode, duration: duration, credential: credential)
            }
        }
        let showKey = selected.map { "\($0.type.rawValue):\($0.tmdbId)" }
        playerManager.configureIntroSkip(episodeKey: progressID, showKey: showKey, showTitle: selected?.title ?? "",
                                         streamSegments: source.segments, fetch: fetch)
        applyTitleSettings(switchAudio: false)
    }

    // MARK: - Title settings

    /// "Sub" / "Dub" from the show's settings, when that option is on.
    private var titleAudioPreference: String? {
        guard let key = selected?.id, case .animeTrack(let track)? = store.titleSettings[key]?.playback.audioDefault else { return nil }
        return track
    }

    /// Hands the show's saved settings to the player. With `switchAudio`
    /// (a change made in Anime Settings) a different default Sub / Dub
    /// switches the playing source too.
    func applyTitleSettings(switchAudio: Bool = true) {
        guard let item = selected else { return }
        let store = store
        let titleKey = item.id
        playerManager.onRecordedSegmentFound = { id, episodeKey, start, videoDuration in
            store.rememberSegmentMatch(titleKey: titleKey, segmentID: id, episodeKey: episodeKey,
                                       start: start, videoDuration: videoDuration)
        }
        playerManager.titleIsAnime = true
        playerManager.applyTitleConfig(store.titleSettings[titleKey]?.playback)
        playerManager.captionVocabulary = ([item.title, details?.show.japaneseTitle ?? "", selectedEpisode?.title ?? ""]
            + (details?.identity?.titles ?? [])).filter { !$0.isEmpty && !$0.hasPrefix("Episode ") }
        if switchAudio, let wanted = titleAudioPreference,
           nativeSources.indices.contains(selectedNativeSourceIndex),
           nativeSources[selectedNativeSourceIndex].audio != wanted,
           let index = nativeSources.firstIndex(where: { $0.audio == wanted && $0.quality == preferredQuality })
            ?? nativeSources.firstIndex(where: { $0.audio == wanted }) {
            switchSource(to: index)
        }
    }

    /// Everything Anime Settings needs for the open show.
    func titleContext() -> TitleContext? {
        guard let item = selected else { return nil }
        let episodes = details?.episodes ?? []
        let server = currentServer
        let current = selectedEpisode.map { Self.episodeRef(item: item, episode: $0) }
        return TitleContext(
            key: item.id,
            item: item,
            kind: .anime,
            playerManager: playerManager,
            seasons: [],
            currentSeason: nil,
            currentEpisode: current,
            loadEpisodes: { _ in episodes.map { Self.episodeRef(item: item, episode: $0) } },
            resolveStream: { [weak self] episode in
                guard let server, let ids = episode.animeIDs,
                      let streams = try? await AnimeKaiClient.streams(base: server.base, episodeIds: ids),
                      !streams.isEmpty else { return nil }
                let audio = self?.titleAudioPreference ?? self?.preferredAudio ?? "Sub"
                return streams.first { $0.audio == audio } ?? streams.first
            },
            apply: { [weak self] in self?.applyTitleSettings() }
        )
    }

    private static func episodeRef(item: MediaItem, episode: AnimeKaiClient.EpisodeInfo) -> EpisodeRef {
        let label = "Episode \(episode.number)"
        return EpisodeRef(id: "tv:\(item.tmdbId):1:\(episode.intNumber)", label: label,
                          title: episode.title == label ? nil : episode.title,
                          season: nil, number: episode.intNumber, animeIDs: episode.ids)
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
        sheetExitHandled = true
        playerManager.keepsPlayingWhenHidden = false
        MiniPlayerCenter.shared.release(playerManager)
        playerManager.wantsFullscreen = false
        isPlayerPresented = false
        detailsTask?.cancel()
        resetPlayback()
        startHeroCycle()
    }

    // MARK: - Leaving a party

    /// An episode the viewer picked (list, Next Episode). Asks a party
    /// viewer first, since their own pick takes them out of the party.
    func chooseEpisode(_ episode: AnimeKaiClient.EpisodeInfo, action: String = "Choosing another episode") {
        let key = partyKey(for: episode)
        guard PartySession.shared.wouldLeave(mediaKey: key) else { selectEpisode(episode); return }
        Task { @MainActor [weak self] in
            guard await PartySession.shared.confirmLeave(action, mediaKey: key) else { return }
            self?.selectEpisode(episode)
        }
    }

    /// The Watch Together key `currentPartyMedia()` would report.
    private func partyKey(for episode: AnimeKaiClient.EpisodeInfo) -> String? {
        selected?.animeSlug.map { "anime:\($0):\(episode.number)" }
    }

    // MARK: - Mini player

    /// Set once the sheet's exit was dealt with (minimized or closed), so
    /// the swipe-down callbacks don't act a second time.
    @ObservationIgnored private var sheetExitHandled = false

    /// Native playback that can carry on in the mini player.
    private var canMinimize: Bool {
        playerManager.player != nil && playerManager.error == nil && !DeviceLink.shared.routesPlayback
    }

    /// The player sheet appeared (opened, or expanded from the mini player).
    func playerSheetAppeared() {
        sheetExitHandled = false
        MiniPlayerCenter.shared.playerWillShow(playerManager)
        // Armed for as long as the sheet is up (the stream may load later):
        // on a swipe-down the inline player's onDisappear can run before we
        // hear about the dismissal. Closing for real cleans up anyway.
        playerManager.keepsPlayingWhenHidden = true
    }

    /// The sheet's close button: shrink into the mini player when the
    /// video can keep playing, otherwise close as before.
    func leavePlayer() {
        sheetExitHandled = true
        if !minimize() { requestClose() }
    }

    /// The sheet went away without the close button (swipe-down).
    func playerSheetDisappeared() {
        // A fullscreen cover hides the sheet too; that isn't leaving.
        guard !sheetExitHandled, !playerManager.wantsFullscreen else { return }
        sheetExitHandled = true
        if !minimize() { requestClose(reopenOnCancel: true) }
    }

    /// Closes the player, asking a party viewer first. `reopenOnCancel`
    /// brings back a sheet that was already swiped away.
    func requestClose(reopenOnCancel: Bool = false) {
        let party = PartySession.shared
        guard party.wouldLeave(closing: self) else { closePlayer(); return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if await party.confirmLeave("Closing the player", closing: self) {
                self.closePlayer()
            } else if reopenOnCancel {
                self.sheetExitHandled = false
                self.isPlayerPresented = true
            }
        }
    }

    @discardableResult
    private func minimize() -> Bool {
        guard canMinimize, let item = selected else {
            playerManager.keepsPlayingWhenHidden = false
            return false
        }
        playerManager.keepsPlayingWhenHidden = true
        isPlayerPresented = false
        // Expanding goes back to the tab that presented the sheet.
        let tab = PartySession.shared.router?.selection
        MiniPlayerCenter.shared.show(
            manager: playerManager,
            title: item.title,
            subtitle: nowPlayingSubtitle,
            artworkURL: item.posterURL,
            expand: { [weak self] in self?.expandFromMini(to: tab) },
            close: { [weak self] in self?.requestClose() }
        )
        return true
    }

    private func expandFromMini(to tab: AppTab?) {
        guard let router = PartySession.shared.router, let tab, router.selection != tab else {
            isPlayerPresented = true
            return
        }
        router.selection = tab
        // Let the tab come on screen first; a hidden tab can't present.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            self?.isPlayerPresented = true
        }
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
