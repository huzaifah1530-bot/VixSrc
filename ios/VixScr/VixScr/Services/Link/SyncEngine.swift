import Foundation

/// iOS side of saved-data sync. Same document and merge rules as the
/// desktop's `src/shared/sync.ts` — keep the two in step.
///
/// The document is also this device's change log: each record carries the
/// time it last changed (`at`, ms since 1970) and deletions stay behind as
/// tombstones, so a merge is commutative, idempotent and safe to repeat after
/// an interrupted transfer. Watch progress uses an `epoch`: an explicit
/// restart, backward seek or mark-unwatched starts a new epoch, which always
/// beats older progress; within an epoch the furthest position wins.
enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else { self = .string(try c.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): if n == n.rounded(), abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }
}

struct SyncDoc: Codable, Equatable, Sendable {
    struct Setting: Codable, Equatable, Sendable { var v: JSONValue; var at: Double }
    struct Server: Codable, Equatable, Sendable { var id: String; var name: String; var base: String; var pos: Int; var at: Double; var del: Bool? }
    struct Item: Codable, Equatable, Sendable {
        var tmdbId: String
        var type: String
        var title: String
        var description: String
        var posterPath: String?
        var backdropPath: String?
        var rating: Double?
        var year: String
        var popularity: Double
        var resumeSeason: Int?
        var resumeEpisode: Int?
        var resumeTitle: String?
        var updatedAt: String?
        var anime: Bool?
    }
    struct ItemRec: Codable, Equatable, Sendable { var key: String; var item: Item; var at: Double; var del: Bool? }
    struct Progress: Codable, Equatable, Sendable {
        var id: String; var position: Double; var duration: Double; var completed: Bool
        var watchedAt: Double; var epoch: Double; var at: Double; var del: Bool?
    }
    struct Search: Codable, Equatable, Sendable { var key: String; var q: String; var at: Double; var del: Bool? }

    var v = 1
    var settings: [String: Setting] = [:]
    var servers: [Server] = []
    var animeServers: [Server] = []
    var favorites: [ItemRec] = []
    var recents: [ItemRec] = []
    var progress: [Progress] = []
    var searches: [Search] = []
    var animeSearches: [Search] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        settings = try c.decodeIfPresent([String: Setting].self, forKey: .settings) ?? [:]
        servers = try c.decodeIfPresent([Server].self, forKey: .servers) ?? []
        animeServers = try c.decodeIfPresent([Server].self, forKey: .animeServers) ?? []
        favorites = try c.decodeIfPresent([ItemRec].self, forKey: .favorites) ?? []
        recents = try c.decodeIfPresent([ItemRec].self, forKey: .recents) ?? []
        progress = try c.decodeIfPresent([Progress].self, forKey: .progress) ?? []
        searches = try c.decodeIfPresent([Search].self, forKey: .searches) ?? []
        animeSearches = try c.decodeIfPresent([Search].self, forKey: .animeSearches) ?? []
    }

    /// Decodes and sanity-checks a document received from the desktop.
    static func validated(_ object: Any?) -> SyncDoc? {
        guard let object, JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let doc = try? JSONDecoder().decode(SyncDoc.self, from: data), doc.v == 1 else { return nil }
        let okServer: (Server) -> Bool = {
            $0.id.count <= 64 && $0.name.count <= 120 && $0.base.count <= 500 &&
                ($0.base.lowercased().hasPrefix("https://") || $0.base.lowercased().hasPrefix("http://"))
        }
        guard doc.servers.count <= 200, doc.animeServers.count <= 200, doc.favorites.count <= 2000,
              doc.recents.count <= 2000, doc.progress.count <= 5000, doc.searches.count <= 1000, doc.animeSearches.count <= 1000,
              doc.servers.allSatisfy(okServer), doc.animeServers.allSatisfy(okServer),
              (doc.favorites + doc.recents).allSatisfy({ ["movie", "tv"].contains($0.item.type) && $0.key.count <= 300 }),
              doc.progress.allSatisfy({ $0.position.isFinite && $0.duration.isFinite && $0.id.count <= 300 })
        else { return nil }
        var clean = doc
        clean.settings = doc.settings.filter { key, setting in
            switch (key, setting.v) {
            case ("credential", .string(let s)): return s.count <= 400
            case ("animeEnabled", .bool): return true
            case ("seekInterval", .number(let n)): return AppStore.seekIntervalOptions.contains(Int(n))
            default: return false
            }
        }
        return clean
    }

    var jsonObject: Any? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

enum SyncMerge {
    static let tombstoneTTL: Double = 90 * 24 * 3600_000
    static let caps = (favorites: 100, recents: 24, progress: 100, searches: 12)
    static let settingKeys = ["credential", "animeEnabled", "seekInterval"]

    private static func lww<T>(_ a: T, _ b: T, at: (T) -> Double, del: (T) -> Bool, tie: (T) -> String) -> T {
        if at(a) != at(b) { return at(a) > at(b) ? a : b }
        if del(a) != del(b) { return del(a) ? a : b }
        return tie(a) >= tie(b) ? a : b
    }

    static func mergeProgress(_ a: SyncDoc.Progress, _ b: SyncDoc.Progress) -> SyncDoc.Progress {
        if a.epoch != b.epoch { return a.epoch > b.epoch ? a : b }
        let ad = a.del == true, bd = b.del == true
        if ad != bd { return ad ? b : a }
        if ad { return a.at >= b.at ? a : b }
        var lead = a.position == b.position ? (a.at >= b.at ? a : b) : (a.position > b.position ? a : b)
        lead.completed = a.completed || b.completed
        lead.duration = max(a.duration, b.duration)
        lead.watchedAt = max(a.watchedAt, b.watchedAt)
        lead.at = max(a.at, b.at)
        return lead
    }

    private static func mergeList<T>(_ a: [T], _ b: [T], key: (T) -> String, pick: (T, T) -> T) -> [T] {
        var order: [String] = []
        var map: [String: T] = [:]
        for r in a + b {
            let k = key(r)
            if let cur = map[k] { map[k] = pick(cur, r) } else { map[k] = r; order.append(k) }
        }
        return order.compactMap { map[$0] }
    }

    private static func normBase(_ b: String) -> String {
        var s = b.trimmingCharacters(in: .whitespaces).lowercased()
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private static func dedupe(_ list: [SyncDoc.Server]) -> [SyncDoc.Server] {
        var keep: [String: SyncDoc.Server] = [:]
        for s in list where s.del != true {
            let k = normBase(s.base)
            if let cur = keep[k], cur.id <= s.id { continue }
            keep[k] = s
        }
        let winners = Set(keep.values.map(\.id))
        return list.map { s in
            guard s.del != true, !winners.contains(s.id) else { return s }
            var t = s; t.del = true; return t
        }
    }

    private static func itemTie(_ r: SyncDoc.ItemRec) -> String {
        "\(r.item.resumeSeason.map(String.init) ?? ""):\(r.item.resumeEpisode.map(String.init) ?? ""):\(r.item.title)"
    }

    static func merge(_ a: SyncDoc, _ b: SyncDoc, now: Double = Date().timeIntervalSince1970 * 1000) -> SyncDoc {
        func prune<T>(_ list: [T], at: (T) -> Double, del: (T) -> Bool) -> [T] {
            list.filter { !del($0) || now - at($0) < tombstoneTTL }
        }
        var out = SyncDoc()
        for k in settingKeys {
            switch (a.settings[k], b.settings[k]) {
            case let (x?, y?):
                if x.at != y.at { out.settings[k] = x.at > y.at ? x : y }
                else { out.settings[k] = jsonString(x.v) >= jsonString(y.v) ? x : y }
            case let (x?, nil): out.settings[k] = x
            case let (nil, y?): out.settings[k] = y
            default: break
            }
        }
        func servers(_ x: [SyncDoc.Server], _ y: [SyncDoc.Server]) -> [SyncDoc.Server] {
            let merged = mergeList(x, y, key: \.id) { p, q in lww(p, q, at: \.at, del: { $0.del == true }, tie: { "\($0.name)|\($0.base)|\($0.pos)" }) }
            return prune(dedupe(merged), at: \.at, del: { $0.del == true })
        }
        out.servers = servers(a.servers, b.servers)
        out.animeServers = servers(a.animeServers, b.animeServers)
        func items(_ x: [SyncDoc.ItemRec], _ y: [SyncDoc.ItemRec]) -> [SyncDoc.ItemRec] {
            prune(mergeList(x, y, key: \.key) { p, q in lww(p, q, at: \.at, del: { $0.del == true }, tie: itemTie) }, at: \.at, del: { $0.del == true })
        }
        out.favorites = items(a.favorites, b.favorites)
        out.recents = items(a.recents, b.recents)
        out.progress = prune(mergeList(a.progress, b.progress, key: \.id, pick: mergeProgress), at: \.at, del: { $0.del == true })
        func searches(_ x: [SyncDoc.Search], _ y: [SyncDoc.Search]) -> [SyncDoc.Search] {
            prune(mergeList(x, y, key: \.key) { p, q in lww(p, q, at: \.at, del: { $0.del == true }, tie: \.q) }, at: \.at, del: { $0.del == true })
        }
        out.searches = searches(a.searches, b.searches)
        out.animeSearches = searches(a.animeSearches, b.animeSearches)
        return out
    }

    /// `dest` becomes a copy of `source`; everything else it had is tombstoned.
    static func replace(_ dest: SyncDoc, with source: SyncDoc, now: Double = Date().timeIntervalSince1970 * 1000) -> SyncDoc {
        var out = source
        out.settings = [:]
        for k in settingKeys {
            if let s = source.settings[k] { out.settings[k] = SyncDoc.Setting(v: s.v, at: max(s.at, dest.settings[k]?.at ?? 0) + 1) }
        }
        let keepS = Set(source.servers.map(\.id)), keepA = Set(source.animeServers.map(\.id))
        out.servers += dest.servers.filter { $0.del != true && !keepS.contains($0.id) }.map { var r = $0; r.del = true; r.at = now; return r }
        out.animeServers += dest.animeServers.filter { $0.del != true && !keepA.contains($0.id) }.map { var r = $0; r.del = true; r.at = now; return r }
        func items(_ mine: [SyncDoc.ItemRec], _ theirs: [SyncDoc.ItemRec]) -> [SyncDoc.ItemRec] {
            let keep = Set(theirs.map(\.key))
            return theirs + mine.filter { $0.del != true && !keep.contains($0.key) }.map { var r = $0; r.del = true; r.at = now; return r }
        }
        out.favorites = items(dest.favorites, source.favorites)
        out.recents = items(dest.recents, source.recents)
        let keepP = Set(source.progress.map(\.id))
        out.progress += dest.progress.filter { $0.del != true && !keepP.contains($0.id) }.map { var r = $0; r.del = true; r.at = now; r.epoch = now; return r }
        func searches(_ mine: [SyncDoc.Search], _ theirs: [SyncDoc.Search]) -> [SyncDoc.Search] {
            let keep = Set(theirs.map(\.key))
            return theirs + mine.filter { $0.del != true && !keep.contains($0.key) }.map { var r = $0; r.del = true; r.at = now; return r }
        }
        out.searches = searches(dest.searches, source.searches)
        out.animeSearches = searches(dest.animeSearches, source.animeSearches)
        return out
    }

    static func jsonString(_ v: JSONValue) -> String {
        (try? String(decoding: JSONEncoder().encode(v), as: UTF8.self)) ?? ""
    }
}

/// Keeps a local SyncDoc in step with `AppStore` and applies merged docs.
@MainActor
final class SyncEngine {
    private let store: AppStore
    private let defaultsKey = "vela_sync_doc"
    private(set) var current: SyncDoc
    private var refreshTask: Task<Void, Never>?
    private var applying = false
    /// Fires when a local edit changed the document (push it to the desktop).
    var onLocalChange: (() -> Void)?

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    init(store: AppStore) {
        self.store = store
        let saved = UserDefaults.standard.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(SyncDoc.self, from: $0) }
        current = SyncDoc()
        current = docFromState(saved)
        save()
        // AppStore's setters always run on the main thread.
        store.onSyncableChange = { @Sendable [weak self] in
            MainActor.assumeIsolated { self?.schedule() }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(current) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }

    private func schedule() {
        guard !applying else { return }
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func refresh() {
        let next = docFromState(current)
        guard next != current else { return }
        current = next
        save()
        onLocalChange?()
    }

    // MARK: - State → doc

    nonisolated static func item(_ i: MediaItem) -> SyncDoc.Item {
        SyncDoc.Item(
            tmdbId: i.tmdbId, type: i.type.rawValue, title: i.title, description: i.description,
            posterPath: i.posterPath, backdropPath: i.backdropPath, rating: i.rating, year: i.year,
            popularity: i.popularity, resumeSeason: i.resumeSeason, resumeEpisode: i.resumeEpisode,
            resumeTitle: i.resumeTitle, updatedAt: i.updatedAt.map { isoFormatter.string(from: $0) }, anime: i.anime
        )
    }

    nonisolated static func mediaItem(_ i: SyncDoc.Item) -> MediaItem? {
        guard let type = MediaItem.MediaType(rawValue: i.type) else { return nil }
        return MediaItem(
            tmdbId: i.tmdbId, type: type, title: i.title, description: i.description,
            posterPath: i.posterPath, backdropPath: i.backdropPath, rating: i.rating, year: i.year,
            popularity: i.popularity, resumeSeason: i.resumeSeason, resumeEpisode: i.resumeEpisode,
            resumeTitle: i.resumeTitle, updatedAt: i.updatedAt.flatMap { isoFormatter.date(from: $0) },
            resumePosition: nil, duration: nil, anime: i.anime
        )
    }

    private func docFromState(_ previous: SyncDoc?) -> SyncDoc {
        let first = previous == nil
        let p = previous ?? SyncDoc()
        let now = Self.nowMs
        var doc = SyncDoc()

        let values: [String: JSONValue] = [
            "credential": .string(store.credential),
            "animeEnabled": .bool(store.animeEnabled),
            "seekInterval": .number(Double(store.seekInterval))
        ]
        for (k, v) in values {
            if let old = p.settings[k], old.v == v { doc.settings[k] = old } else { doc.settings[k] = .init(v: v, at: first ? 1 : now) }
        }

        func servers(_ cur: [(id: String, name: String, base: String)], _ old: [SyncDoc.Server]) -> [SyncDoc.Server] {
            let byId = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var out: [SyncDoc.Server] = cur.enumerated().map { pos, s in
                if let o = byId[s.id], o.del != true, o.name == s.name, o.base == s.base, o.pos == pos { return o }
                return SyncDoc.Server(id: s.id, name: s.name, base: s.base, pos: pos, at: first ? 1 : now, del: nil)
            }
            let live = Set(cur.map(\.id))
            for o in old where !live.contains(o.id) {
                if o.del == true { out.append(o) } else { var t = o; t.del = true; t.at = now; out.append(t) }
            }
            return out
        }
        doc.servers = servers(store.servers.map { ($0.id.uuidString, $0.name, $0.base) }, p.servers)
        doc.animeServers = servers(store.animeServers.map { ($0.id.uuidString, $0.name, $0.base) }, p.animeServers)

        func items(_ cur: [MediaItem], _ old: [SyncDoc.ItemRec], cap: Int) -> [SyncDoc.ItemRec] {
            let byKey = Dictionary(old.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            var seen = Set<String>()
            var out: [SyncDoc.ItemRec] = []
            for i in cur {
                let key = "\(i.type.rawValue):\(i.tmdbId)"
                guard seen.insert(key).inserted else { continue }
                let it = Self.item(i)
                if let o = byKey[key], o.del != true, o.item == it { out.append(o); continue }
                out.append(.init(key: key, item: it, at: first ? (i.updatedAt.map { $0.timeIntervalSince1970 * 1000 } ?? 1) : now, del: nil))
            }
            let trimming = cur.count >= cap
            for o in old where !seen.contains(o.key) {
                if o.del == true { out.append(o) } else if !trimming { var t = o; t.del = true; t.at = now; out.append(t) }
            }
            return out
        }
        doc.favorites = items(store.favorites, p.favorites, cap: SyncMerge.caps.favorites)
        doc.recents = items(store.recents, p.recents, cap: SyncMerge.caps.recents)

        let oldP = Dictionary(p.progress.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seenP = Set<String>()
        for w in store.watchProgress where seenP.insert(w.id).inserted {
            let watchedAt = w.lastWatchedAt.timeIntervalSince1970 * 1000
            if let o = oldP[w.id], o.del != true, o.position == w.position, o.duration == w.duration, o.completed == w.completed {
                doc.progress.append(o); continue
            }
            var epoch = oldP[w.id]?.epoch ?? 0
            if let o = oldP[w.id], o.del != true, !first, w.position < o.position - 30 || (o.completed && !w.completed) { epoch = now }
            doc.progress.append(.init(id: w.id, position: w.position, duration: w.duration, completed: w.completed,
                                      watchedAt: watchedAt, epoch: epoch, at: first ? watchedAt : now, del: nil))
        }
        let trimP = store.watchProgress.count >= SyncMerge.caps.progress
        for o in p.progress where !seenP.contains(o.id) {
            if o.del == true { doc.progress.append(o) } else if !trimP { var t = o; t.del = true; t.at = now; t.epoch = now; doc.progress.append(t) }
        }

        func searches(_ cur: [String], _ old: [SyncDoc.Search]) -> [SyncDoc.Search] {
            let byKey = Dictionary(old.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            var seen = Set<String>()
            var out: [SyncDoc.Search] = []
            for (i, q) in cur.enumerated() {
                let key = q.lowercased()
                guard seen.insert(key).inserted else { continue }
                if let o = byKey[key], o.del != true, o.q == q { out.append(o) } else { out.append(.init(key: key, q: q, at: first ? Double(cur.count - i) : now, del: nil)) }
            }
            let trimming = cur.count >= SyncMerge.caps.searches
            for o in old where !seen.contains(o.key) {
                if o.del == true { out.append(o) } else if !trimming { var t = o; t.del = true; t.at = now; out.append(t) }
            }
            return out
        }
        doc.searches = searches(store.searchHistory, p.searches)
        doc.animeSearches = searches(store.animeSearchHistory, p.animeSearches)
        return doc
    }

    // MARK: - Doc → state

    /// Server ids from the desktop are UUIDs; anything else gets a stable one.
    private static func uuid(_ id: String) -> UUID {
        if let u = UUID(uuidString: id) { return u }
        var bytes = Array(id.utf8)
        while bytes.count < 16 { bytes += bytes.isEmpty ? [0] : bytes }
        var h = [UInt8](repeating: 0, count: 16)
        for (i, b) in bytes.enumerated() { h[i % 16] = h[i % 16] &* 31 &+ b }
        return UUID(uuid: (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8], h[9], h[10], h[11], h[12], h[13], h[14], h[15]))
    }

    private func apply(_ doc: SyncDoc) {
        applying = true
        defer { applying = false }
        if case .string(let s)? = doc.settings["credential"]?.v { store.credential = s }
        if case .bool(let b)? = doc.settings["animeEnabled"]?.v { store.animeEnabled = b }
        if case .number(let n)? = doc.settings["seekInterval"]?.v, AppStore.seekIntervalOptions.contains(Int(n)) { store.seekInterval = Int(n) }

        func live(_ l: [SyncDoc.Server]) -> [SyncDoc.Server] {
            l.filter { $0.del != true }.sorted { $0.pos != $1.pos ? $0.pos < $1.pos : $0.id < $1.id }
        }
        let servers = live(doc.servers).map { StreamServer(id: Self.uuid($0.id), name: $0.name, base: $0.base) }
        if !servers.isEmpty { store.servers = servers }
        store.animeServers = live(doc.animeServers).map { AnimeServer(id: Self.uuid($0.id), name: $0.name, base: $0.base) }

        func items(_ l: [SyncDoc.ItemRec], cap: Int) -> [MediaItem] {
            l.filter { $0.del != true }.sorted { $0.at > $1.at }.prefix(cap).compactMap { Self.mediaItem($0.item) }
        }
        store.favorites = items(doc.favorites, cap: SyncMerge.caps.favorites)
        store.recents = items(doc.recents, cap: SyncMerge.caps.recents)
        store.watchProgress = doc.progress.filter { $0.del != true }.sorted { $0.watchedAt > $1.watchedAt }
            .prefix(SyncMerge.caps.progress)
            .map { WatchProgress(id: $0.id, position: $0.position, duration: $0.duration,
                                 lastWatchedAt: Date(timeIntervalSince1970: $0.watchedAt / 1000), completed: $0.completed) }
        func searches(_ l: [SyncDoc.Search]) -> [String] {
            l.filter { $0.del != true }.sorted { $0.at > $1.at }.prefix(SyncMerge.caps.searches).map(\.q)
        }
        store.searchHistory = searches(doc.searches)
        store.animeSearchHistory = searches(doc.animeSearches)
    }

    // MARK: - Public API

    /// Merges a desktop document into ours and applies it.
    func mergeRemote(_ remote: SyncDoc) {
        refreshTask?.cancel()
        refresh()
        let merged = SyncMerge.merge(current, remote)
        apply(merged)
        current = SyncMerge.merge(docFromState(merged), merged)
        save()
    }

    /// Fresh copy: this iPhone becomes a copy of `source`.
    func replaceFromRemote(_ source: SyncDoc) {
        refreshTask?.cancel()
        refresh()
        let replaced = SyncMerge.replace(current, with: source)
        apply(replaced)
        current = SyncMerge.merge(docFromState(replaced), replaced)
        save()
    }
}
