import Foundation
import Observation
import SwiftUI

/// The main screen state machine. This is the SwiftUI/MVVM analogue of the
/// giant `state` object + free functions (loadHome, runSearch, openContent,
/// selectSeason, selectEpisode, switchServer, ...) in index.html.
@MainActor
@Observable
final class CatalogViewModel {
    let store: AppStore
    private let client: TMDBClient

    // Home + search
    private(set) var homeRows: [MediaRow] = []
    private(set) var searchItems: [MediaItem] = []
    var searchQuery: String = ""
    private(set) var isLoadingHome = false
    private(set) var homeErrorMessage: String?
    private(set) var homeLoaded = false
    // Search loading state — true while the debounce is pending or the
    // network request is in flight. Drives the spinner in the search UI.
    private(set) var isSearching = false
    private var searchTask: Task<[MediaItem], Never>?
    private var searchDebounceTask: Task<Void, Never>?
    /// Incremented at the start of every `runSearch` call. Lets us discard
    /// results from a superseded search without needing reference equality
    /// on Task (which is a struct in Swift 6 and doesn't support ===).
    private var searchGeneration = 0

    // Hero / currently previewed item on the home screen.
    // Cycles through homeRows items every 10s; never shows recents.
    private(set) var hero: MediaItem?
    private var heroCycleIndex = 0
    private var heroCycleTask: Task<Void, Never>?

    // Player sheet. Presented from the root of the tab hierarchy (see
    // `RootView`) rather than from an individual tab, so opening a title
    // from any tab (Home, Favourites, a deep link) shows the player over
    // the whole app instead of only over whichever tab happened to
    // present it.
    var isPlayerPresented = false
    private(set) var selected: MediaItem?
    private(set) var tvDetails: TVDetails?
    private(set) var selectedSeason: SeasonSummary?
    private(set) var episodes: [Episode] = []
    private(set) var selectedEpisode: Episode?
    var episodeQuery: String = ""
    private(set) var isLoadingEpisodes = false
    private(set) var episodeErrorMessage: String?
    private(set) var currentServerIndex = 0
    private(set) var currentStreamURL: URL?
    private(set) var currentNativeVideoURL: URL?
    private(set) var nativeSources: [StreamURLExtractor.ResolvedStream] = []
    private(set) var selectedNativeSourceIndex = 0
    private(set) var isResolvingStream = false
    private(set) var cast: [CastMember] = []

    let playerManager = VideoPlayerManager()
    private var streamResolutionTask: Task<Void, Never>?
    private var rejectedNativeStreamURLs: Set<URL> = []

    private var castTask: Task<Void, Never>?

    // Toasts
    var toastMessage: String?
    private var toastTask: Task<Void, Never>?

    init(store: AppStore, client: TMDBClient = TMDBClient()) {
        self.store = store
        self.client = client
    }

    // MARK: - Derived collections

    var filteredHomeRows: [MediaRow] {
        var rows = homeRows
        let recents = store.homeRecents
        if !recents.isEmpty, searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            rows = [MediaRow(title: "Continue watching", subtitle: "Saved on this device", items: recents)] + rows
        }
        return applyContentFilter(rows).filter { !$0.items.isEmpty }
    }

    var displayedRows: [MediaRow] {
        if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            return applyContentFilter([MediaRow(title: "Search results", subtitle: "Live and fuzzy TMDB matches", items: searchItems)])
        }
        return filteredHomeRows
    }

    var totalResultCount: Int {
        Set(displayedRows.flatMap(\.items).map(\.id)).count
    }

    private func applyContentFilter(_ rows: [MediaRow]) -> [MediaRow] {
        rows.map { row in
            // Dedupe per row, like `dedupe(...)` on every row in index.html.
            // TMDB can return the same id twice (e.g. trending + popular
            // overlap), which would otherwise collide in ForEach.
            var seen = Set<String>()
            // Anime lives in its own tab.
            let items = row.items
                .filter { !$0.isAnime }
                .filter(passesContentFilter)
                .filter { seen.insert($0.id).inserted }
            return MediaRow(title: row.title, subtitle: row.subtitle, items: items)
        }
    }

    private func passesContentFilter(_ item: MediaItem) -> Bool {
        switch store.contentFilter {
        case .movie: return item.type == .movie
        case .tv: return item.type == .tv
        case .favorites: return store.isFavorite(item)
        case .all: return true
        }
    }

    private func allKnownItems() -> [MediaItem] {
        var seen = Set<String>()
        var out: [MediaItem] = []
        for item in homeRows.flatMap(\.items) + searchItems {
            if seen.insert(item.id).inserted { out.append(item) }
        }
        return out
    }

    // MARK: - Home loading

    @MainActor
    func loadHome() async {
        guard !store.credential.trimmingCharacters(in: .whitespaces).isEmpty else {
            hero = nil
            homeRows = []
            homeErrorMessage = nil
            return
        }

        isLoadingHome = true
        homeErrorMessage = nil

        // Snapshot into a local before the async let block. `store` is a
        // non-Sendable, MainActor-only type; reading `store.credential`
        // directly inside `async let`'s initializer expression counts as
        // sending main-actor state across an isolation boundary under
        // Swift 6.2's stricter checking.
        let credential = store.credential

        do {
            async let trending = client.list("/trending/all/week", credential: credential)
            async let moviePopular = client.list("/movie/popular", credential: credential, query: ["page": "1"])
            async let tvPopular = client.list("/tv/popular", credential: credential, query: ["page": "1"])
            async let movieTop = client.list("/movie/top_rated", credential: credential, query: ["page": "1"])
            async let tvTop = client.list("/tv/top_rated", credential: credential, query: ["page": "1"])

            let (trendingItems, moviePopularItems, tvPopularItems, movieTopItems, tvTopItems) = try await (
                trending.compactMap { $0.normalized() },
                moviePopular.compactMap { $0.normalized(forcedType: .movie) },
                tvPopular.compactMap { $0.normalized(forcedType: .tv) },
                movieTop.compactMap { $0.normalized(forcedType: .movie) },
                tvTop.compactMap { $0.normalized(forcedType: .tv) }
            )

            homeRows = [
                MediaRow(title: "Trending this week", subtitle: "Live from TMDB trending", items: trendingItems),
                MediaRow(title: "Popular movies", subtitle: "Current TMDB movie results", items: moviePopularItems),
                MediaRow(title: "Popular TV shows", subtitle: "Current TMDB show results", items: tvPopularItems),
                MediaRow(title: "Top rated movies", subtitle: "Highly rated TMDB films", items: movieTopItems),
                MediaRow(title: "Top rated TV", subtitle: "Highly rated TMDB series", items: tvTopItems)
            ]
            .map { MediaRow(title: $0.title, subtitle: $0.subtitle, items: $0.items.filter { !$0.isAnime }) }
            .filter { !$0.items.isEmpty }

            if let first = homeRows.flatMap(\.items).first {
                hero = first
                heroCycleIndex = 0
            }
            homeLoaded = true
            startHeroCycle()
        } catch {
            homeErrorMessage = error.localizedDescription
        }

        isLoadingHome = false
    }

    func previewHero(fromQueryPreview query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            // Search cleared — restart the cycle from the current index
            startHeroCycle()
            return
        }
        // Pause cycle while user is actively searching
        heroCycleTask?.cancel()
        guard FuzzySearch.compactForMatch(trimmed).count >= 3 else { return }
        let local = localFuzzyItems(query: trimmed, limit: 1).first
        if let local { hero = local }
    }

    // MARK: - Hero cycling

    /// Cycles the hero card through all home items every 10 seconds.
    /// Never includes recents — the LastWatchedCard handles those.
    ///
    /// Before advancing the hero, pre-warms the next item's backdrop image
    /// into URLCache so AsyncImage finds it already loaded and shows no
    /// placeholder flash. The cycle also pauses while the player sheet is
    /// open — no point loading images the user cannot see.
    private func startHeroCycle() {
        heroCycleTask?.cancel()
        heroCycleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
                guard !Task.isCancelled, let self else { return }

                // Pause while the player is open — no visible hero, no wasted
                // network and CPU for image pre-warming.
                guard !isPlayerPresented else { continue }

                let allItems = homeRows.flatMap(\.items)
                guard allItems.count > 1 else { continue }

                let nextIndex = (heroCycleIndex + 1) % allItems.count
                let nextItem = allItems[nextIndex]

                // Pre-warm: fetch the backdrop into the shared URL cache so
                // AsyncImage sees it as already loaded when the hero updates.
                // Fire-and-forget — if it fails the image just loads normally.
                if let url = nextItem.backdropURL {
                    await prewarmImage(url: url)
                }

                guard !Task.isCancelled, !isPlayerPresented else { continue }

                heroCycleIndex = nextIndex
                withAnimation(.easeInOut(duration: 0.8)) {
                    hero = nextItem
                }
            }
        }
    }

    /// Downloads `url` into `URLCache.shared` if not already cached.
    /// Uses a low-priority background task so it doesn't compete with
    /// foreground requests (TMDB API calls, episode loads, etc.).
    private func prewarmImage(url: URL) async {
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        // Already cached — nothing to do.
        if URLCache.shared.cachedResponse(for: request) != nil { return }
        var bgRequest = URLRequest(url: url)
        bgRequest.networkServiceType = .background
        do {
            let (data, response) = try await URLSession.shared.data(for: bgRequest)
            let cached = CachedURLResponse(response: response, data: data)
            URLCache.shared.storeCachedResponse(cached, for: URLRequest(url: url))
        } catch {
            // Network failure is fine — cycle still advances, image loads
            // normally with a brief placeholder.
        }
    }

    // MARK: - Search

    func debounceSearch(_ value: String) {
        searchQuery = value
        searchDebounceTask?.cancel()

        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            isSearching = false
            searchItems = []
            // Restore hero to wherever the cycle currently is — don't snap
            // back to item 0. startHeroCycle() owns this, not debounceSearch.
            startHeroCycle()
            return
        }

        // Mark as searching immediately for UI feedback.
        // Do NOT run previewHero here — it does synchronous fuzzy matching
        // across every loaded item on the main thread and is the cause of
        // per-keystroke lag. It runs inside the debounced task instead.
        isSearching = true
        heroCycleTask?.cancel()

        searchDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            // Now safe to do the fuzzy preview — debounce has settled
            previewHero(fromQueryPreview: trimmed)
            await runSearch(value)
        }
    }

    private func localFuzzyItems(query: String, limit: Int = 12, year: String = "") -> [MediaItem] {
        guard FuzzySearch.compactForMatch(query).count >= 3 else { return [] }
        return Array(FuzzySearch.rankAndFilter(items: allKnownItems(), query: query, year: year).prefix(limit))
    }

    @MainActor
    func runSearch(_ query: String) async {
        searchTask?.cancel()
        searchQuery = query
        searchGeneration += 1
        let generation = searchGeneration

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            isSearching = false
            searchItems = []
            return
        }

        let parsed = FuzzySearch.parseSearchQuery(trimmed)
        // previewHero is already called by debounceSearch before runSearch
        // is invoked — no need to run it again here (double fuzzy scan).

        guard !store.credential.trimmingCharacters(in: .whitespaces).isEmpty else {
            isSearching = false
            searchItems = []
            return
        }
        guard FuzzySearch.compactForMatch(parsed.titleQuery).count >= 2 else {
            isSearching = false
            searchItems = []
            return
        }

        let task = Task { [weak self] () -> [MediaItem] in
            guard let self else { return [] }
            do {
                let raw = try await client.list("/search/multi", credential: store.credential, query: ["query": parsed.titleQuery, "include_adult": "false", "page": "1"])
                let rawItems = raw.compactMap { $0.normalized() }.filter { !$0.isAnime }

                var items = FuzzySearch.rankAndFilter(items: rawItems, query: parsed.titleQuery, year: parsed.year)

                if items.isEmpty {
                    let localItems = localFuzzyItems(query: parsed.titleQuery, year: parsed.year)
                    if let bestLocal = localItems.first {
                        if let fuzzyRaw = try? await client.list("/search/multi", credential: store.credential, query: ["query": bestLocal.title, "include_adult": "false", "page": "1"]) {
                            let fuzzyItems = fuzzyRaw.compactMap { $0.normalized() }
                            let cleaned = FuzzySearch.rankAndFilter(items: fuzzyItems, query: bestLocal.title, year: parsed.year, threshold: 0.72)
                            var seen = Set<String>()
                            items = (localItems + cleaned).filter { seen.insert($0.id).inserted }
                        } else {
                            items = localItems
                        }
                    }
                }
                return items
            } catch {
                let localItems = localFuzzyItems(query: parsed.titleQuery, year: parsed.year)
                return localItems
            }
        }
        searchTask = task
        let result = await task.value
        // Discard stale results: if searchGeneration advanced while we were
        // awaiting, a newer runSearch call has already taken over.
        guard searchGeneration == generation else { return }
        isSearching = false
        searchItems = result
        if let first = result.first { hero = first }
        // Save to history after a successful search with results
        if !result.isEmpty {
            store.addSearchHistory(searchQuery.trimmingCharacters(in: .whitespaces))
        }
    }

    func commitSearch(openBest: Bool) async {
        searchDebounceTask?.cancel()
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            await runSearch("")
            return
        }
        // Do NOT save history here — runSearch saves after a successful
        // (non-empty) result, which avoids persisting zero-result queries.
        await runSearch(query)
        if openBest, let best = searchItems.first {
            await open(best)
        } else if openBest {
            showToast("No result to open")
        }
    }

    // MARK: - Opening content / player

    @MainActor
    func open(_ item: MediaItem) async {
        heroCycleTask?.cancel()
        selected = item
        hero = item
        tvDetails = nil
        selectedSeason = nil
        selectedEpisode = nil
        episodes = []
        currentServerIndex = 0
        currentStreamURL = nil
        currentNativeVideoURL = nil
        nativeSources = []
        selectedNativeSourceIndex = 0
        isResolvingStream = false
        streamResolutionTask?.cancel()
        playerManager.cleanup()
        playerManager.setNowPlayingMetadata(title: item.title, subtitle: nil, artworkURL: item.posterURL)
        cast = []
        isPlayerPresented = true

        // Cancel any in-flight cast fetch, otherwise a slow response for a
        // previously-opened title can overwrite the cast of this one.
        castTask?.cancel()
        castTask = Task { await loadCast(for: item) }

        if item.type == .movie {
            store.addRecent(item)
            startPlaybackForCurrentSelection()
            return
        }

        isLoadingEpisodes = true
        episodeErrorMessage = nil
        do {
            let details = try await client.tvDetails(id: item.tmdbId, credential: store.credential)
            tvDetails = details
            let seasons = details.usableSeasons
            guard let firstSeason = seasons.first else {
                throw TMDBError.decoding
            }
            let targetSeasonNumber = item.resumeSeason ?? firstSeason.seasonNumber
            await selectSeason(targetSeasonNumber, preferredEpisode: item.resumeEpisode)
        } catch {
            isLoadingEpisodes = false
            episodeErrorMessage = error.localizedDescription
        }
    }

    /// Opens a title directly from a TMDB id, used for deep links (Universal
    /// Links / custom URL scheme), mirroring `openContentByTmdbId`. Tries
    /// movie first, falls back to tv, same as the JS version.
    @MainActor
    func openByTMDBId(_ id: String) async {
        guard !store.credential.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if let movie = try? await client.detail(type: .movie, tmdbId: id, credential: store.credential) {
            await open(movie)
            return
        }
        if let tv = try? await client.detail(type: .tv, tmdbId: id, credential: store.credential) {
            await open(tv)
            return
        }
        showToast("Could not find TMDB title \(id)")
    }

    @MainActor
    func selectSeason(_ seasonNumber: Int, preferredEpisode: Int? = nil) async {
        guard let details = tvDetails,
              let seasonMeta = details.usableSeasons.first(where: { $0.seasonNumber == seasonNumber }),
              let tvId = selected?.tmdbId, !tvId.isEmpty else {
            // Clear the spinner, otherwise `open()` leaves it spinning forever.
            isLoadingEpisodes = false
            return
        }

        selectedSeason = seasonMeta
        episodeQuery = ""
        isLoadingEpisodes = true
        episodes = []

        do {
            let seasonDetails = try await client.season(tvId: tvId, seasonNumber: seasonNumber, credential: store.credential)
            // Inject seasonNumber into each episode so the NextEpisodeButton
            // can display "S2E1" without re-querying the season number.
            let fetchedEpisodes = (seasonDetails.episodes ?? []).map { ep -> Episode in
                var e = ep
                e.seasonNumber = seasonNumber
                return e
            }
            episodes = fetchedEpisodes
            isLoadingEpisodes = false

            if let target = fetchedEpisodes.first(where: { $0.episodeNumber == preferredEpisode }) ?? fetchedEpisodes.first {
                await selectEpisode(target)
            }
        } catch {
            isLoadingEpisodes = false
            episodeErrorMessage = error.localizedDescription
        }
    }

    var filteredEpisodes: [Episode] {
        let query = FuzzySearch.normalizeForMatch(episodeQuery)
        guard !query.isEmpty else { return episodes }
        return episodes.filter { episode in
            let haystack = FuzzySearch.normalizeForMatch([
                String(episode.episodeNumber),
                episode.name ?? "",
                episode.overview ?? ""
            ].joined(separator: " "))
            return haystack.contains(query) || FuzzySearch.fuzzyScore(query: query, title: episode.name ?? "") >= 0.62
        }
    }

    /// The episode that comes after the currently-playing one in the loaded
    /// season. Returns nil when on the last episode of the last season, or
    /// when no episode is selected yet. The button uses this to offer
    /// "Play Next" without any extra network call.
    /// The season after the current one, when the current episode is the
    /// last in its season.
    private var nextSeason: SeasonSummary? {
        guard nextEpisode == nil, let current = selectedSeason, let details = tvDetails,
              let last = episodes.map(\.episodeNumber).max(),
              selectedEpisode?.episodeNumber == last else { return nil }
        return details.usableSeasons.first { $0.seasonNumber > current.seasonNumber }
    }

    /// Label for the player's Next Episode button, crossing seasons.
    var nextEpisodeLabel: String? {
        if let next = nextEpisode {
            return "S\(next.seasonNumber ?? selectedSeason?.seasonNumber ?? 0)E\(next.episodeNumber)" + (next.name.map { " · \($0)" } ?? "")
        }
        if let season = nextSeason { return "S\(season.seasonNumber)E1" }
        return nil
    }

    func playNextEpisode() async {
        if let next = nextEpisode {
            await selectEpisode(next)
        } else if let season = nextSeason {
            await selectSeason(season.seasonNumber)
        }
    }

    var nextEpisode: Episode? {
        guard let current = selectedEpisode else { return nil }
        let sorted = episodes.sorted { $0.episodeNumber < $1.episodeNumber }
        guard let idx = sorted.firstIndex(where: { $0.id == current.id }),
              idx + 1 < sorted.count else { return nil }
        return sorted[idx + 1]
    }

    /// The regular server the user last picked. Changing episode must NOT
    /// silently drop back to server 0.
    private var activeServer: StreamServer? {
        if store.servers.indices.contains(currentServerIndex) {
            return store.servers[currentServerIndex]
        }
        return store.servers.first
    }

    var currentServerName: String {
        store.servers.indices.contains(currentServerIndex) ? store.servers[currentServerIndex].name : "Select"
    }

    @MainActor
    func selectEpisode(_ episode: Episode) async {
        selectedEpisode = episode
        guard let item = selected, let season = selectedSeason else { return }
        let episodeLabel = "S\(season.seasonNumber) · E\(episode.episodeNumber)"
        let subtitle = episode.name.map { "\(episodeLabel) — \($0)" } ?? episodeLabel
        playerManager.setNowPlayingMetadata(title: item.title, subtitle: subtitle, artworkURL: item.posterURL)
        store.addRecent(item, season: season.seasonNumber, episode: episode.episodeNumber, episodeTitle: episode.name)
        startPlaybackForCurrentSelection()
    }

    @MainActor
    func switchServer(to index: Int) {
        guard selected != nil, store.servers.indices.contains(index) else { return }
        currentServerIndex = index
        startPlaybackForCurrentSelection()
        showToast("Switched to \(currentServerName)")
    }

    /// Builds the stream for the selected movie / episode on the current server.
    private func startPlaybackForCurrentSelection() {
        guard let item = selected else { return }
        rejectedNativeStreamURLs.removeAll()
        if item.type == .movie {
            currentStreamURL = activeServer?.movieURL(tmdbId: item.tmdbId)
        } else if let season = selectedSeason, let episode = selectedEpisode {
            currentStreamURL = activeServer?.tvURL(tmdbId: item.tmdbId, season: season.seasonNumber, episode: episode.episodeNumber)
        } else {
            return
        }
        resolvePlaybackURL()
    }

    func reloadPlayer() {
        let url = currentStreamURL
        rejectedNativeStreamURLs.removeAll()
        currentStreamURL = nil
        currentNativeVideoURL = nil
        nativeSources = []
        selectedNativeSourceIndex = 0
        playerManager.cleanup()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            currentStreamURL = url
        }
    }

    private func resolvePlaybackURL() {
        currentNativeVideoURL = nil
        isResolvingStream = true
        streamResolutionTask?.cancel()
        guard let pageURL = currentStreamURL else { return }
        streamResolutionTask = Task { @MainActor [weak self] in
            let mode = await StreamURLExtractor.determinePlaybackMode(for: pageURL)
            guard let self, !Task.isCancelled, self.currentStreamURL == pageURL else { return }
            self.isResolvingStream = false
            switch mode {
            case .native(let sources):
                self.nativeSources = sources
                self.selectedNativeSourceIndex = 0
                self.loadNativeSource(at: 0)
            case .embed:
                self.playerManager.cleanup()
                if let item = self.selected {
                    self.playerManager.setNowPlayingMetadata(
                        title: item.title,
                        subtitle: self.nowPlayingEpisodeSubtitle,
                        artworkURL: item.posterURL
                    )
                }
            }
        }
    }

    func switchNativeSource(to index: Int) {
        guard nativeSources.indices.contains(index) else { return }
        selectedNativeSourceIndex = index
        loadNativeSource(at: index)
    }

    private func loadNativeSource(at index: Int) {
        guard nativeSources.indices.contains(index) else { return }
        let source = nativeSources[index]
        // Flush the previous item while its progress callback still carries
        // its own movie or episode ID.
        playerManager.cleanup()
        currentNativeVideoURL = source.url
        let progressID = currentProgressID
        playerManager.onProgressUpdate = { [weak self] position, duration in
            self?.recordPlaybackProgress(position: position, duration: duration, progressID: progressID)
        }
        playerManager.load(
            url: source.url,
            requestHeaders: source.requestHeaders,
            httpCookies: source.httpCookies,
            startPosition: playbackResumePosition,
            progressId: progressID,
            mediaTitle: selected?.title,
            subtitle: nowPlayingEpisodeSubtitle,
            artworkURL: selected?.posterURL
        )
    }

    private var nowPlayingEpisodeSubtitle: String? {
        guard let season = selectedSeason, let episode = selectedEpisode else { return nil }
        let number = "S\(season.seasonNumber) · E\(episode.episodeNumber)"
        guard let name = episode.name, !name.isEmpty else { return number }
        return "\(number) — \(name)"
    }

    private var currentProgressID: String {
        guard let item = selected else { return "movie:unknown" }
        if item.type == .tv, let season = selectedSeason, let episode = selectedEpisode {
            return "tv:\(item.tmdbId):\(season.seasonNumber):\(episode.episodeNumber)"
        }
        return "movie:\(item.tmdbId)"
    }

    var playbackResumePosition: Double {
        guard let progress = store.progress(for: currentProgressID),
              progress.position > 0, progress.progress < 0.95 else { return 0 }
        return progress.position
    }

    func recordPlaybackProgress(position: Double, duration: Double) {
        recordPlaybackProgress(position: position, duration: duration, progressID: currentProgressID)
    }

    func updateWebPlaybackPosition(_ position: Double, duration: Double, isPlaying: Bool) {
        playerManager.updateWebPlaybackPosition(position, duration: duration, isPlaying: isPlaying)
    }

    private func recordPlaybackProgress(position: Double, duration: Double, progressID: String) {
        guard position.isFinite, duration.isFinite, position >= 0, duration > 0 else { return }
        store.saveProgress(WatchProgress(
            id: progressID,
            position: position,
            duration: duration,
            lastWatchedAt: Date(),
            completed: position / duration >= 0.95
        ))
    }

    func adoptNativeStream(_ url: URL, cookies: [HTTPCookie]) {
        guard currentNativeVideoURL != url, !rejectedNativeStreamURLs.contains(url) else { return }
        let source = StreamURLExtractor.ResolvedStream(
            id: url.absoluteString,
            name: "Native stream",
            url: url,
            requestHeaders: ["User-Agent": StreamURLExtractor.userAgent],
            httpCookies: cookies
        )
        nativeSources = [source]
        selectedNativeSourceIndex = 0
        loadNativeSource(at: 0)
    }

    func rejectNativeStream(_ url: URL) {
        guard currentNativeVideoURL == url else { return }
        rejectedNativeStreamURLs.insert(url)
        playerManager.cleanup()
        currentNativeVideoURL = nil
        nativeSources = []
        selectedNativeSourceIndex = 0
    }

    @MainActor
    func closePlayer() {
        isPlayerPresented = false
        rejectedNativeStreamURLs.removeAll()
        currentStreamURL = nil
        currentNativeVideoURL = nil
        nativeSources = []
        selectedNativeSourceIndex = 0
        isResolvingStream = false
        streamResolutionTask?.cancel()
        playerManager.cleanup()
        startHeroCycle()
    }

    // MARK: - Cast

    @MainActor
    private func loadCast(for item: MediaItem) async {
        do {
            let response = try await client.credits(type: item.type, tmdbId: item.tmdbId, credential: store.credential)
            guard !Task.isCancelled, selected?.id == item.id else { return }
            cast = Array((response.cast ?? []).prefix(15))
        } catch {
            guard !Task.isCancelled, selected?.id == item.id else { return }
            cast = []
        }
    }

    // MARK: - Toasts

    func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_550_000_000)
            guard !Task.isCancelled else { return }
            self?.toastMessage = nil
        }
    }

    // MARK: - Favorites convenience for hero/player

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
}
