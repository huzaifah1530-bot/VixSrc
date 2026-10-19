import Foundation
import Observation

/// Local persistence layer, mirroring every `localStorage` key used in the
/// Electron app (index.html):
///   vixsrc_live_tmdb_credential, vixsrc_live_favorites, vixsrc_live_recents,
///   vixsrc_live_content_filter, vixsrc_live_search_history,
///   vixsrc_live_card_size, vixsrc_live_perf_mode, vixsrc_live_ultra_perf_mode,
///   vixsrc_live_servers
///
/// UserDefaults is the direct native analogue of localStorage: both are
/// simple, synchronous, on-device key/value stores.
// Not marked @MainActor deliberately: `VelaApp` creates this in a `@State`
// default-value expression, which is evaluated in a nonisolated context, so a
// @MainActor initialiser would not be callable there. Every current access
// already happens from the main actor (SwiftUI view bodies and the
// @MainActor CatalogViewModel).
@Observable
final class AppStore {
    @ObservationIgnored private let defaults: UserDefaults

    /// Called after any value the device link syncs changes (SyncEngine).
    @ObservationIgnored var onSyncableChange: (() -> Void)?

    enum Keys {
        static let credential = "vixsrc_live_tmdb_credential"
        static let favorites = "vixsrc_live_favorites"
        static let recents = "vixsrc_live_recents"
        static let contentFilter = "vixsrc_live_content_filter"
        static let searchHistory = "vixsrc_live_search_history"
        static let cardSize = "vixsrc_live_card_size"
        static let perfMode = "vixsrc_live_perf_mode"
        static let ultraPerfMode = "vixsrc_live_ultra_perf_mode"
        static let servers = "vixsrc_live_servers"
        static let watchProgress = "vixsrc_live_watch_progress"
        static let animeServers = "vixsrc_live_anime_servers"
        static let animeSearchHistory = "vixsrc_live_anime_search_history"
        static let seekInterval = "vixsrc_live_seek_interval"
        static let animeEnabled = "vixsrc_live_anime_enabled"
    }

    /// Optional built-in credential. The Electron app hardcodes one directly
    /// in index.html (`HARDCODED_TMDB_CREDENTIAL`); leave this empty to force
    /// users through Settings, matching a "clean" build.
    static let hardcodedTMDBCredential = ""

    // NOTE: These are hand-written computed properties over @ObservationIgnored
    // backing storage, using the macro-provided access(keyPath:) /
    // withMutation(keyPath:) hooks.
    //
    // Why not stored properties with `didSet`? @Observable rewrites each
    // stored property into a get/set pair, and a property cannot have both an
    // explicit accessor and a `didSet` observer — that combination does not
    // compile. Doing it manually keeps SwiftUI observation working *and*
    // persists to UserDefaults on every mutation (the localStorage-write
    // behaviour of the Electron app).
    @ObservationIgnored private var storedCredential: String
    var credential: String {
        get {
            access(keyPath: \.credential)
            return storedCredential
        }
        set {
            withMutation(keyPath: \.credential) {
                storedCredential = newValue
                defaults.set(newValue, forKey: Keys.credential)
                onSyncableChange?()
            }
        }
    }

    @ObservationIgnored private var storedFavorites: [MediaItem]
    var favorites: [MediaItem] {
        get {
            access(keyPath: \.favorites)
            return storedFavorites
        }
        set {
            withMutation(keyPath: \.favorites) {
                storedFavorites = newValue
                save(newValue, key: Keys.favorites)
                onSyncableChange?()
            }
        }
    }

    @ObservationIgnored private var storedRecents: [MediaItem]
    var recents: [MediaItem] {
        get {
            access(keyPath: \.recents)
            return storedRecents
        }
        set {
            withMutation(keyPath: \.recents) {
                storedRecents = newValue
                save(newValue, key: Keys.recents)
                onSyncableChange?()
            }
        }
    }

    @ObservationIgnored private var storedContentFilter: ContentFilter
    var contentFilter: ContentFilter {
        get {
            access(keyPath: \.contentFilter)
            return storedContentFilter
        }
        set {
            withMutation(keyPath: \.contentFilter) {
                storedContentFilter = newValue
                defaults.set(newValue.rawValue, forKey: Keys.contentFilter)
                onSyncableChange?()
            }
        }
    }

    @ObservationIgnored private var storedSearchHistory: [String]
    var searchHistory: [String] {
        get {
            access(keyPath: \.searchHistory)
            return storedSearchHistory
        }
        set {
            withMutation(keyPath: \.searchHistory) {
                storedSearchHistory = newValue
                defaults.set(newValue, forKey: Keys.searchHistory)
                onSyncableChange?()
            }
        }
    }

    @ObservationIgnored private var storedAnimeSearchHistory: [String]
    var animeSearchHistory: [String] {
        get {
            access(keyPath: \.animeSearchHistory)
            return storedAnimeSearchHistory
        }
        set {
            withMutation(keyPath: \.animeSearchHistory) {
                storedAnimeSearchHistory = newValue
                defaults.set(newValue, forKey: Keys.animeSearchHistory)
                onSyncableChange?()
            }
        }
    }

    /// Seconds skipped by double-tapping the player or the skip buttons.
    static let seekIntervalOptions = [5, 10, 15, 30]
    @ObservationIgnored private var storedSeekInterval: Int
    var seekInterval: Int {
        get {
            access(keyPath: \.seekInterval)
            return storedSeekInterval
        }
        set {
            withMutation(keyPath: \.seekInterval) {
                storedSeekInterval = newValue
                defaults.set(newValue, forKey: Keys.seekInterval)
                onSyncableChange?()
            }
        }
    }

    /// Shows the Anime tab and enables anime servers. On by default.
    @ObservationIgnored private var storedAnimeEnabled: Bool
    var animeEnabled: Bool {
        get {
            access(keyPath: \.animeEnabled)
            return storedAnimeEnabled
        }
        set {
            withMutation(keyPath: \.animeEnabled) {
                storedAnimeEnabled = newValue
                defaults.set(newValue, forKey: Keys.animeEnabled)
                onSyncableChange?()
            }
        }
    }

    @ObservationIgnored private var storedCardSize: CardSize
    var cardSize: CardSize {
        get {
            access(keyPath: \.cardSize)
            return storedCardSize
        }
        set {
            withMutation(keyPath: \.cardSize) {
                storedCardSize = newValue
                defaults.set(newValue.rawValue, forKey: Keys.cardSize)
                onSyncableChange?()
            }
        }
    }

    @ObservationIgnored private var storedPerformanceMode: Bool
    var performanceMode: Bool {
        get {
            access(keyPath: \.performanceMode)
            return storedPerformanceMode
        }
        set {
            withMutation(keyPath: \.performanceMode) {
                storedPerformanceMode = newValue
                defaults.set(newValue, forKey: Keys.perfMode)
            }
        }
    }

    @ObservationIgnored private var storedUltraPerformanceMode: Bool
    var ultraPerformanceMode: Bool {
        get {
            access(keyPath: \.ultraPerformanceMode)
            return storedUltraPerformanceMode
        }
        set {
            withMutation(keyPath: \.ultraPerformanceMode) {
                storedUltraPerformanceMode = newValue
                defaults.set(newValue, forKey: Keys.ultraPerfMode)
            }
        }
    }

    @ObservationIgnored private var storedServers: [StreamServer]
    var servers: [StreamServer] {
        get {
            access(keyPath: \.servers)
            return storedServers
        }
        set {
            withMutation(keyPath: \.servers) {
                storedServers = newValue
                save(newValue, key: Keys.servers)
                onSyncableChange?()
            }
        }
    }

    @ObservationIgnored private var storedAnimeServers: [AnimeServer]
    var animeServers: [AnimeServer] {
        get {
            access(keyPath: \.animeServers)
            return storedAnimeServers
        }
        set {
            withMutation(keyPath: \.animeServers) {
                storedAnimeServers = newValue
                save(newValue, key: Keys.animeServers)
                onSyncableChange?()
            }
        }
    }

    @ObservationIgnored private var storedWatchProgress: [WatchProgress]
    var watchProgress: [WatchProgress] {
        get {
            access(keyPath: \.watchProgress)
            return storedWatchProgress
        }
        set {
            withMutation(keyPath: \.watchProgress) {
                storedWatchProgress = newValue
                save(newValue, key: Keys.watchProgress)
                onSyncableChange?()
            }
        }
    }

    enum ContentFilter: String, CaseIterable {
        case all, movie, tv, favorites
    }

    enum CardSize: String {
        case compact, large
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.storedCredential = {
            let hardcoded = AppStore.hardcodedTMDBCredential.trimmingCharacters(in: .whitespacesAndNewlines)
            if !hardcoded.isEmpty { return hardcoded }
            return defaults.string(forKey: Keys.credential) ?? ""
        }()
        self.storedFavorites = AppStore.load([MediaItem].self, key: Keys.favorites, defaults: defaults) ?? []
        self.storedRecents = AppStore.load([MediaItem].self, key: Keys.recents, defaults: defaults) ?? []
        self.storedContentFilter = ContentFilter(rawValue: defaults.string(forKey: Keys.contentFilter) ?? "all") ?? .all
        self.storedSearchHistory = defaults.stringArray(forKey: Keys.searchHistory) ?? []
        self.storedAnimeSearchHistory = defaults.stringArray(forKey: Keys.animeSearchHistory) ?? []
        self.storedAnimeEnabled = defaults.object(forKey: Keys.animeEnabled) as? Bool ?? true
        let savedSeek = defaults.integer(forKey: Keys.seekInterval)
        self.storedSeekInterval = AppStore.seekIntervalOptions.contains(savedSeek) ? savedSeek : 10
        self.storedCardSize = CardSize(rawValue: defaults.string(forKey: Keys.cardSize) ?? "large") ?? .large
        self.storedPerformanceMode = defaults.bool(forKey: Keys.perfMode)
        self.storedUltraPerformanceMode = defaults.bool(forKey: Keys.ultraPerfMode)
        self.storedServers = AppStore.load([StreamServer].self, key: Keys.servers, defaults: defaults) ?? StreamServer.defaults
        self.storedAnimeServers = AppStore.load([AnimeServer].self, key: Keys.animeServers, defaults: defaults) ?? AnimeServer.defaults
        self.storedWatchProgress = AppStore.load([WatchProgress].self, key: Keys.watchProgress, defaults: defaults) ?? []
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Favorites

    func isFavorite(_ item: MediaItem) -> Bool {
        favorites.contains { $0.id == item.id }
    }

    func toggleFavorite(_ item: MediaItem) {
        if isFavorite(item) {
            favorites.removeAll { $0.id == item.id }
        } else {
            favorites = [item] + favorites.filter { $0.id != item.id }
            if favorites.count > 100 { favorites = Array(favorites.prefix(100)) }
        }
    }

    // MARK: Recents / continue watching

    func addRecent(_ item: MediaItem, season: Int? = nil, episode: Int? = nil, episodeTitle: String? = nil) {
        var snapshot = item
        snapshot.resumeSeason = season
        snapshot.resumeEpisode = episode
        snapshot.resumeTitle = episodeTitle
        snapshot.updatedAt = Date()
        recents = ([snapshot] + recents.filter { $0.id != item.id }).prefix(24).map { $0 }
    }

    func removeFromHistory(_ item: MediaItem) {
        recents.removeAll { $0.id == item.id }
        if item.type == .movie {
            watchProgress.removeAll { $0.id == "movie:\(item.tmdbId)" }
        } else {
            watchProgress.removeAll { $0.id.hasPrefix("tv:\(item.tmdbId):") }
        }
    }

    var sortedRecents: [MediaItem] {
        recents.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    /// Home shows only TMDB movies and shows; the Anime tab shows only anime.
    var homeRecents: [MediaItem] { sortedRecents.filter { !$0.isAnime } }
    var animeRecents: [MediaItem] { sortedRecents.filter(\.isAnimeCatalog) }

    func progress(for id: String) -> WatchProgress? {
        watchProgress.first { $0.id == id }
    }

    func progress(for item: MediaItem) -> WatchProgress? {
        if item.type == .tv, let season = item.resumeSeason, let episode = item.resumeEpisode {
            return progress(for: "tv:\(item.tmdbId):\(season):\(episode)")
        }
        if item.type == .movie {
            return progress(for: "movie:\(item.tmdbId)")
        }
        return watchProgress.first { $0.id.hasPrefix("tv:\(item.tmdbId):") }
    }

    func saveProgress(_ progress: WatchProgress) {
        watchProgress = [progress] + watchProgress.filter { $0.id != progress.id }
        if watchProgress.count > 100 {
            watchProgress = Array(watchProgress.prefix(100))
        }
    }

    // MARK: Search history

    func addSearchHistory(_ query: String) {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2 else { return }
        searchHistory = ([clean] + searchHistory.filter { $0.caseInsensitiveCompare(clean) != .orderedSame }).prefix(12).map { $0 }
    }

    func clearSearchHistory() {
        searchHistory = []
    }

    func addAnimeSearchHistory(_ query: String) {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2 else { return }
        animeSearchHistory = ([clean] + animeSearchHistory.filter { $0.caseInsensitiveCompare(clean) != .orderedSame }).prefix(12).map { $0 }
    }

    // MARK: Servers

    func addOrUpdateServer(_ server: StreamServer, replacing index: Int?) {
        if let index, servers.indices.contains(index) {
            servers[index] = server
        } else {
            servers.append(server)
        }
    }

    func removeServer(at index: Int) {
        guard servers.indices.contains(index) else { return }
        servers.remove(at: index)
    }

    func addOrUpdateAnimeServer(_ server: AnimeServer, replacing index: Int?) {
        if let index, animeServers.indices.contains(index) {
            animeServers[index] = server
        } else {
            animeServers.append(server)
        }
    }

    func removeAnimeServer(at index: Int) {
        guard animeServers.indices.contains(index) else { return }
        animeServers.remove(at: index)
    }

    // MARK: Backup (export / import)

    /// Everything the app persists, as one versioned JSON document.
    struct Backup: Codable {
        var app = "Vela"
        var version = 1
        var exportedAt = Date()
        var credential: String
        var favorites: [MediaItem]
        var recents: [MediaItem]
        var watchProgress: [WatchProgress]
        var searchHistory: [String]
        var animeSearchHistory: [String]?
        var seekInterval: Int?
        var animeEnabled: Bool?
        var servers: [StreamServer]
        var animeServers: [AnimeServer]
        var contentFilter: String
        var cardSize: String
        var performanceMode: Bool
        var ultraPerformanceMode: Bool
    }

    func exportBackup() throws -> Data {
        let backup = Backup(
            credential: credential,
            favorites: favorites,
            recents: recents,
            watchProgress: watchProgress,
            searchHistory: searchHistory,
            animeSearchHistory: animeSearchHistory,
            seekInterval: seekInterval,
            animeEnabled: animeEnabled,
            servers: servers,
            animeServers: animeServers,
            contentFilter: contentFilter.rawValue,
            cardSize: cardSize.rawValue,
            performanceMode: performanceMode,
            ultraPerformanceMode: ultraPerformanceMode
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    /// Replaces all local data with the backup's contents.
    func importBackup(_ data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(Backup.self, from: data)
        guard backup.app == "Vela" else { throw CocoaError(.fileReadCorruptFile) }
        credential = backup.credential
        favorites = backup.favorites
        recents = backup.recents
        watchProgress = backup.watchProgress
        searchHistory = backup.searchHistory
        animeSearchHistory = backup.animeSearchHistory ?? []
        animeEnabled = backup.animeEnabled ?? true
        if let seek = backup.seekInterval, AppStore.seekIntervalOptions.contains(seek) { seekInterval = seek }
        servers = backup.servers.isEmpty ? StreamServer.defaults : backup.servers
        animeServers = backup.animeServers
        contentFilter = ContentFilter(rawValue: backup.contentFilter) ?? .all
        cardSize = CardSize(rawValue: backup.cardSize) ?? .large
        performanceMode = backup.performanceMode
        ultraPerformanceMode = backup.ultraPerformanceMode
    }
}
