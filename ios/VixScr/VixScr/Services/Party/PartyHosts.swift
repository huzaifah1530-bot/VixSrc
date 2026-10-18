import Foundation

// Watch Together adapters for the two player screens.

enum PartyItems {
    static func dict(_ item: MediaItem) -> [String: JSONValue] {
        guard let data = try? JSONEncoder().encode(SyncEngine.item(item)),
              let dict = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return [:] }
        return dict
    }

    static func mediaItem(_ dict: [String: JSONValue]) -> MediaItem? {
        guard let data = try? JSONEncoder().encode(dict),
              let item = try? JSONDecoder().decode(SyncDoc.Item.self, from: data) else { return nil }
        return SyncEngine.mediaItem(item)
    }
}

extension CatalogViewModel: PartyPlayerHost {
    func currentPartyMedia() -> PartyMedia? {
        guard let item = selected else { return nil }
        if item.type == .movie {
            return PartyMedia(kind: "tmdb", key: "movie:\(item.tmdbId)", item: PartyItems.dict(item), season: nil,
                              episode: nil, episodeTitle: nil, slug: nil, title: nil, server: currentServerName)
        }
        guard let s = selectedSeason?.seasonNumber, let e = selectedEpisode?.episodeNumber else { return nil }
        return PartyMedia(kind: "tmdb", key: "tv:\(item.tmdbId):\(s):\(e)", item: PartyItems.dict(item), season: s,
                          episode: .number(Double(e)), episodeTitle: selectedEpisode?.name, slug: nil, title: nil, server: currentServerName)
    }

    func loadPartyMedia(_ media: PartyMedia) async {
        guard media.kind == "tmdb", var item = PartyItems.mediaItem(media.item) else { return }
        if item.type == .tv, selected?.tmdbId == item.tmdbId, let s = media.season {
            // Same show: just move to the episode.
            await selectSeason(s, preferredEpisode: media.tmdbEpisode)
        } else {
            item.resumeSeason = media.season
            item.resumeEpisode = media.tmdbEpisode
            await open(item)
        }
        if let index = store.servers.firstIndex(where: { $0.name.caseInsensitiveCompare(media.server) == .orderedSame }),
           index != currentServerIndex {
            switchServer(to: index)
        }
    }

    func nextPartyMedia(after media: PartyMedia) async -> PartyMedia? {
        guard currentPartyMedia()?.key == media.key, let item = selected, item.type == .tv else { return nil }
        if let next = nextEpisode, let s = selectedSeason?.seasonNumber {
            var m = media
            m.key = "tv:\(item.tmdbId):\(s):\(next.episodeNumber)"
            m.season = s; m.episode = .number(Double(next.episodeNumber)); m.episodeTitle = next.name
            return m
        }
        if let label = nextEpisodeLabel, let s = Int(label.dropFirst().prefix { $0.isNumber }) {
            var m = media
            m.key = "tv:\(item.tmdbId):\(s):1"
            m.season = s; m.episode = .number(1); m.episodeTitle = nil
            return m
        }
        return nil
    }

    func stepDownQuality() -> String? { nil }
}

extension AnimeViewModel: PartyPlayerHost {
    func currentPartyMedia() -> PartyMedia? {
        guard let item = selected, let ep = selectedEpisode, let slug = item.animeSlug else { return nil }
        return PartyMedia(kind: "anime", key: "anime:\(slug):\(ep.number)", item: PartyItems.dict(item), season: nil,
                          episode: .string(ep.number), episodeTitle: nil, slug: slug, title: item.title,
                          server: currentServer?.name ?? "")
    }

    func loadPartyMedia(_ media: PartyMedia) async {
        guard media.kind == "anime", let slug = media.slug, let number = media.animeEpisode,
              var item = PartyItems.mediaItem(media.item),
              let base = store.animeServers.first?.base else { return }
        if selected?.animeSlug == slug, let ep = details?.episodes.first(where: { $0.number == number }) {
            selectEpisode(ep)
            return
        }
        // Slugs differ between sites; fall back to finding the show by title.
        var useSlug = slug
        if (try? await AnimeKaiClient.details(base: base, slug: slug)) == nil,
           let found = try? await AnimeKaiClient.findSlug(base: base, title: media.title ?? item.title) {
            useSlug = found
        }
        item.tmdbId = MediaItem.animeCatalogPrefix + useSlug
        item.anime = true
        item.resumeEpisode = Int(Double(number) ?? 1)
        open(item)
    }

    func nextPartyMedia(after media: PartyMedia) async -> PartyMedia? {
        guard currentPartyMedia()?.key == media.key, let next = nextEpisode, let slug = media.slug else { return nil }
        var m = media
        m.key = "anime:\(slug):\(next.number)"
        m.episode = .string(next.number)
        return m
    }

    func stepDownQuality() -> String? {
        guard nativeSources.indices.contains(selectedNativeSourceIndex) else { return nil }
        let cur = nativeSources[selectedNativeSourceIndex]
        func height(_ q: String?) -> Int { Int(q?.filter(\.isNumber) ?? "") ?? Int.max }
        let lower = nativeSources.enumerated()
            .filter { $0.element.audio == cur.audio && height($0.element.quality) < height(cur.quality) }
            .max { height($0.element.quality) < height($1.element.quality) }
        guard let lower else { return nil }
        switchSource(to: lower.offset)
        return lower.element.quality
    }
}
