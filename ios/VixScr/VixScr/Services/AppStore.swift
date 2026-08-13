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
@Observable
final class AppStore {
    private let defaults: UserDefaults

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
    }

    /// Optional built-in credential. The Electron app hardcodes one directly
    /// in index.html (`HARDCODED_TMDB_CREDENTIAL`); leave this empty to force
    /// users through Settings, matching a "clean" build.
    static let hardcodedTMDBCredential = ""

    var credential: String {
        didSet { defaults.set(credential, forKey: Keys.credential) }
    }

    var favorites: [MediaItem] {
        didSet { save(favorites, key: Keys.favorites) }
    }

    var recents: [MediaItem] {
        didSet { save(recents, key: Keys.recents) }
    }

    var contentFilter: ContentFilter {
        didSet { defaults.set(contentFilter.rawValue, forKey: Keys.contentFilter) }
    }

    var searchHistory: [String] {
        didSet { defaults.set(searchHistory, forKey: Keys.searchHistory) }
    }

    var cardSize: CardSize {
        didSet { defaults.set(cardSize.rawValue, forKey: Keys.cardSize) }
    }

    var performanceMode: Bool {
        didSet { defaults.set(performanceMode, forKey: Keys.perfMode) }
    }

    var ultraPerformanceMode: Bool {
        didSet { defaults.set(ultraPerformanceMode, forKey: Keys.ultraPerfMode) }
    }

    var servers: [StreamServer] {
        didSet { save(servers, key: Keys.servers) }
    }

    enum ContentFilter: String, CaseIterable {
        case all, movie, tv, favorites
    }

    enum CardSize: String {
        case compact, large
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.credential = {
            let hardcoded = AppStore.hardcodedTMDBCredential.trimmingCharacters(in: .whitespacesAndNewlines)
            if !hardcoded.isEmpty { return hardcoded }
            return defaults.string(forKey: Keys.credential) ?? ""
        }()
        self.favorites = AppStore.load([MediaItem].self, key: Keys.favorites, defaults: defaults) ?? []
        self.recents = AppStore.load([MediaItem].self, key: Keys.recents, defaults: defaults) ?? []
        self.contentFilter = ContentFilter(rawValue: defaults.string(forKey: Keys.contentFilter) ?? "all") ?? .all
        self.searchHistory = defaults.stringArray(forKey: Keys.searchHistory) ?? []
        self.cardSize = CardSize(rawValue: defaults.string(forKey: Keys.cardSize) ?? "large") ?? .large
        self.performanceMode = defaults.bool(forKey: Keys.perfMode)
        self.ultraPerformanceMode = defaults.bool(forKey: Keys.ultraPerfMode)
        self.servers = AppStore.load([StreamServer].self, key: Keys.servers, defaults: defaults) ?? StreamServer.defaults
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

    var sortedRecents: [MediaItem] {
        recents.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
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
}
