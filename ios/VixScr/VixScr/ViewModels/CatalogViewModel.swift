import Foundation
import Observation

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
    private var searchTask: Task<[MediaItem], Never>?
    private var searchDebounceTask: Task<Void, Never>?

    // Hero / currently previewed item on the home screen.
    private(set) var hero: MediaItem?

    // Player sheet
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
    private(set) var cast: [CastMember] = []

    // Settings sheet
    var isSettingsPresented = false

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
        let recents = store.sortedRecents
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
            let items = row.items
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

        do {
            async let trending = client.list("/trending/all/week", credential: store.credential)
            async let moviePopular = client.list("/movie/popular", credential: store.credential, query: ["page": "1"])
            async let tvPopular = client.list("/tv/popular", credential: store.credential, query: ["page": "1"])
            async let movieTop = client.list("/movie/top_rated", credential: store.credential, query: ["page": "1"])
            async let tvTop = client.list("/tv/top_rated", credential: store.credential, query: ["page": "1"])

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
            ].filter { !$0.items.isEmpty }

            if let first = homeRows.flatMap(\.items).first {
                hero = first
            }
            homeLoaded = true
        } catch {
            homeErrorMessage = error.localizedDescription
        }

        isLoadingHome = false
    }

    func previewHero(fromQueryPreview query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            hero = homeRows.flatMap(\.items).first
            return
        }
        guard FuzzySearch.compactForMatch(trimmed).count >= 3 else { return }
        let local = localFuzzyItems(query: trimmed, limit: 1).first
        if let local { hero = local }
    }

    // MARK: - Search

    func debounceSearch(_ value: String) {
        // Track the query immediately so `commitSearch` (triggered by return
        // before the debounce fires) doesn't act on a stale value.
        searchQuery = value
        searchDebounceTask?.cancel()
        searchDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard !Task.isCancelled else { return }
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

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            searchItems = []
            return
        }

        let parsed = FuzzySearch.parseSearchQuery(trimmed)
        previewHero(fromQueryPreview: parsed.titleQuery)

        guard !store.credential.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchItems = []
            return
        }
        guard FuzzySearch.compactForMatch(parsed.titleQuery).count >= 2 else {
            searchItems = []
            return
        }

        let task = Task { [weak self] () -> [MediaItem] in
            guard let self else { return [] }
            do {
                let raw = try await client.list("/search/multi", credential: store.credential, query: ["query": parsed.titleQuery, "include_adult": "false", "page": "1"])
                let rawItems = raw.compactMap { $0.normalized() }

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
        guard !Task.isCancelled else { return }
        searchItems = result
        if let first = result.first { hero = first }
    }

    func commitSearch(openBest: Bool) async {
        searchDebounceTask?.cancel()
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            await runSearch("")
            return
        }
        store.addSearchHistory(query)
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
        selected = item
        hero = item
        tvDetails = nil
        selectedSeason = nil
        selectedEpisode = nil
        episodes = []
        currentServerIndex = 0
        currentStreamURL = nil
        cast = []
        isPlayerPresented = true

        // Cancel any in-flight cast fetch, otherwise a slow response for a
        // previously-opened title can overwrite the cast of this one.
        castTask?.cancel()
        castTask = Task { await loadCast(for: item) }

        if item.type == .movie {
            store.addRecent(item)
            currentStreamURL = activeServer?.movieURL(tmdbId: item.tmdbId)
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
            let fetchedEpisodes = seasonDetails.episodes ?? []
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

    /// The server the user last picked. `index.html` reads `getServers()` fresh
    /// on every URL build and keeps `state.currentServerIndex`, so changing
    /// episode must NOT silently drop back to server 0.
    private var activeServer: StreamServer? {
        if store.servers.indices.contains(currentServerIndex) {
            return store.servers[currentServerIndex]
        }
        return store.servers.first
    }

    @MainActor
    func selectEpisode(_ episode: Episode) async {
        selectedEpisode = episode
        guard let item = selected, let season = selectedSeason else { return }
        currentStreamURL = activeServer?.tvURL(tmdbId: item.tmdbId, season: season.seasonNumber, episode: episode.episodeNumber)
        store.addRecent(item, season: season.seasonNumber, episode: episode.episodeNumber, episodeTitle: episode.name)
    }

    @MainActor
    func switchServer(to index: Int) {
        guard store.servers.indices.contains(index), let item = selected else { return }
        currentServerIndex = index
        let server = store.servers[index]
        if item.type == .movie {
            currentStreamURL = server.movieURL(tmdbId: item.tmdbId)
        } else if let season = selectedSeason, let episode = selectedEpisode {
            currentStreamURL = server.tvURL(tmdbId: item.tmdbId, season: season.seasonNumber, episode: episode.episodeNumber)
        }
        showToast("Switched to \(server.name)")
    }

    func reloadPlayer() {
        let url = currentStreamURL
        currentStreamURL = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            currentStreamURL = url
        }
    }

    @MainActor
    func closePlayer() {
        isPlayerPresented = false
        currentStreamURL = nil
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
