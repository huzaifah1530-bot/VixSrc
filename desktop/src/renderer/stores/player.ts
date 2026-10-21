// Playback orchestration (port of the iOS CatalogViewModel / AnimeViewModel
// playback paths). Components only render this state; all source choice,
// fallback and progress keys live here.
import { create } from 'zustand'
import type { AnimeDetails, AnimeEpisode, MediaItem, ResolvedStream } from '@shared/types'
import { useSettings } from './settings'
import { useLibrary } from './library'
import { toast } from './ui'
import { animeSlug } from '@/lib/tmdb'
import { isAddonUrl } from '@shared/stremio'

export interface TvContext {
  seasons: { seasonNumber: number; episodeCount: number }[]
  season: number
  episode: number
  episodeTitle?: string | null
}

export interface AnimeContext {
  details: AnimeDetails
  episode: AnimeEpisode
  serverIndex: number
  slugs: Record<number, string>
}

interface PlayerState {
  open: boolean
  kind: 'tmdb' | 'anime'
  item: MediaItem | null
  subtitle: string | null
  tv: TvContext | null
  anime: AnimeContext | null
  serverIndex: number
  sources: ResolvedStream[]
  sourceIndex: number
  embedUrl: string | null
  resolving: boolean
  status: string | null
  error: string | null
  progressId: string
  resumeAt: number
  rejected: string[]
  /** increments every time a new source should be (re)loaded */
  loadToken: number

  playTmdb: (item: MediaItem, tv?: TvContext | null, serverIndex?: number) => void
  playAnime: (item: MediaItem, details: AnimeDetails, episode: AnimeEpisode, serverIndex?: number, slugs?: Record<number, string>) => void
  selectServer: (index: number) => void
  selectSource: (index: number) => void
  rejectCurrent: (reason?: string) => void
  adoptSniffed: (url: string, referer?: string) => void
  reload: () => void
  next: () => void
  hasNext: () => boolean
  close: () => void
}

let generation = 0
let preferredAudio: 'Sub' | 'Dub' = 'Sub'
let preferredQuality = 'Auto'

const resumeFor = (id: string) => {
  const p = useLibrary.getState().watchProgress.find(x => x.id === id)
  return p && p.position > 0 && p.duration > 0 && p.position / p.duration < 0.95 ? p.position : 0
}

function embedFor(item: MediaItem, tv: TvContext | null, index: number): string | null {
  const s = useSettings.getState().servers[index]
  if (!s) return null
  const base = s.base.replace(/\/+$/, '')
  return item.type === 'movie' ? `${base}/movie/${item.tmdbId}` : tv ? `${base}/tv/${item.tmdbId}/${tv.season}/${tv.episode}` : null
}

export const usePlayer = create<PlayerState>((set, get) => {
  const resetPlayback = () => {
    generation++
    window.vela.setPlaybackHeaders(null)
    return { sources: [], sourceIndex: 0, embedUrl: null, resolving: false, status: null, error: null, rejected: [] }
  }

  const loadSource = (index: number) => {
    const src = get().sources[index]
    if (!src) return
    // Main injects these on every media/xhr request from the UI while playing.
    window.vela.setPlaybackHeaders(Object.keys(src.requestHeaders).length ? src.requestHeaders : null)
    set(s => ({ sourceIndex: index, error: null, loadToken: s.loadToken + 1 }))
  }

  const resolveTmdb = async () => {
    const { item, tv, serverIndex } = get()
    if (!item) return
    const gen = ++generation
    const url = embedFor(item, tv, serverIndex)
    if (!url) { set({ error: 'No servers configured. Add one in Settings.' }); return }
    set({ resolving: true, status: `Finding a stream on ${useSettings.getState().servers[serverIndex]?.name}…`, embedUrl: null, sources: [] })
    let sources: ResolvedStream[] = []
    try { sources = await window.vela.resolveStreams(url) } catch { /* fall back to embed */ }
    if (gen !== generation) return
    if (sources.length) {
      set({ resolving: false, status: null, sources })
      loadSource(0)
    } else if (isAddonUrl(url)) {
      // Addon servers have no web player to fall back to.
      set({ resolving: false, status: null, error: `${useSettings.getState().servers[serverIndex]?.name ?? 'This server'} found no streams. Try another server.` })
    } else {
      set({ resolving: false, status: null, embedUrl: url })
    }
  }

  const resolveAnime = async () => {
    const { anime } = get()
    if (!anime) return
    const gen = ++generation
    const server = useSettings.getState().animeServers[anime.serverIndex]
    if (!server) { set({ error: 'No anime servers configured.' }); return }
    set({ resolving: true, status: `Loading episode ${anime.episode.number}…` })
    try {
      const sources = await window.vela.anime.streams(server.base, anime.episode.ids)
      if (gen !== generation) return
      const idx = Math.max(0,
        sources.findIndex(s => s.audio === preferredAudio && s.quality === preferredQuality) >= 0
          ? sources.findIndex(s => s.audio === preferredAudio && s.quality === preferredQuality)
          : sources.findIndex(s => s.audio === preferredAudio))
      set({ resolving: false, status: null, sources })
      loadSource(idx)
    } catch (err) {
      if (gen !== generation) return
      set({ resolving: false, status: null, error: `${server.name}: ${(err as Error).message.replace(/^Error invoking remote method '[^']+': (Error: )?/, '')}` })
    }
  }

  return {
    open: false, kind: 'tmdb', item: null, subtitle: null, tv: null, anime: null,
    serverIndex: 0, sources: [], sourceIndex: 0, embedUrl: null, resolving: false,
    status: null, error: null, progressId: '', resumeAt: 0, rejected: [], loadToken: 0,

    playTmdb: (item, tv = null, serverIndex) => {
      const progressId = item.type === 'movie' || !tv ? `movie:${item.tmdbId}` : `tv:${item.tmdbId}:${tv.season}:${tv.episode}`
      const subtitle = tv ? `S${tv.season} · E${tv.episode}${tv.episodeTitle ? ' — ' + tv.episodeTitle : ''}` : item.year || null
      useLibrary.getState().addRecent(item, tv?.season, tv?.episode, tv?.episodeTitle)
      set({
        ...resetPlayback(), open: true, kind: 'tmdb', item, tv, anime: null, subtitle,
        serverIndex: serverIndex ?? (get().kind === 'tmdb' ? get().serverIndex : 0),
        progressId, resumeAt: resumeFor(progressId)
      })
      if (get().serverIndex >= useSettings.getState().servers.length) set({ serverIndex: 0 })
      resolveTmdb()
    },

    playAnime: (item, details, episode, serverIndex = 0, slugs) => {
      const n = Math.floor(Number(episode.number) || 0)
      const progressId = `tv:${item.tmdbId}:1:${n}`
      const generic = episode.title === `Episode ${episode.number}`
      useLibrary.getState().addRecent(item, 1, n, generic ? null : episode.title)
      set({
        ...resetPlayback(), open: true, kind: 'anime', item, tv: null,
        anime: { details, episode, serverIndex, slugs: slugs ?? { [serverIndex]: animeSlug(item) ?? details.show.slug } },
        serverIndex,
        subtitle: generic ? `Episode ${episode.number}` : `E${episode.number} — ${episode.title}`,
        progressId, resumeAt: resumeFor(progressId)
      })
      resolveAnime()
    },

    selectServer: async index => {
      const { kind, item, tv, anime } = get()
      if (!item) return
      if (kind === 'tmdb') { get().playTmdb(item, tv, index); return }
      if (!anime || index === anime.serverIndex) return
      const server = useSettings.getState().animeServers[index]
      if (!server) return
      toast(`Switched to ${server.name}`)
      const gen = ++generation
      set({ ...resetPlayback(), serverIndex: index, resolving: true, status: `Finding on ${server.name}…` })
      try {
        const slug = anime.slugs[index] ?? (await window.vela.anime.findSlug(server.base, item.title))
        if (gen !== generation) return
        if (!slug) throw new Error(`Couldn't find this title on ${server.name}`)
        const details = await window.vela.anime.details(server.base, slug)
        if (gen !== generation) return
        const ep = details.episodes.find(e => e.number === anime.episode.number) ?? details.episodes[0]
        if (!ep) throw new Error('This episode isn’t available on this server')
        get().playAnime(item, details, ep, index, { ...anime.slugs, [index]: slug })
      } catch (err) {
        if (gen === generation) set({ resolving: false, status: null, error: (err as Error).message.replace(/^Error invoking remote method '[^']+': (Error: )?/, '') })
      }
    },

    selectSource: index => {
      const s = get().sources[index]
      if (!s) return
      if (s.audio) preferredAudio = s.audio
      if (s.quality) preferredQuality = s.quality
      set({ resumeAt: resumeFor(get().progressId) })
      loadSource(index)
    },

    /** Current native source failed: same audio first, then any, then embed / error. */
    rejectCurrent: reason => {
      const { sources, sourceIndex, rejected, kind, item, tv, serverIndex } = get()
      const cur = sources[sourceIndex]
      if (!cur) return
      const nextRejected = [...rejected, cur.url]
      set({ rejected: nextRejected })
      const untried = sources.map((s, i) => ({ s, i })).filter(x => !nextRejected.includes(x.s.url))
      const next = untried.find(x => x.s.audio === cur.audio) ?? untried[0]
      if (next) { loadSource(next.i); return }
      window.vela.setPlaybackHeaders(null)
      if (kind === 'tmdb' && item) {
        const url = embedFor(item, tv, serverIndex)
        if (isAddonUrl(url)) set({ sources: [], error: 'None of the streams would play. Try another server.' })
        else set({ sources: [], embedUrl: url, error: url ? null : reason ?? 'Stream failed to play' })
      } else {
        set({ sources: [], error: 'None of the streams would play. Try another server.' })
      }
    },

    /** The embed played an HLS stream — take it over with the native player. */
    adoptSniffed: (url, referer) => {
      const { embedUrl, rejected, sources } = get()
      if (!embedUrl || rejected.includes(url) || sources.length) return
      const headers: Record<string, string> = {}
      if (referer) { headers.Referer = referer; try { headers.Origin = new URL(referer).origin } catch { /* ignore */ } }
      set({ sources: [{ id: url, name: 'Native stream', url, requestHeaders: headers, subtitles: [] }], embedUrl: null, resumeAt: resumeFor(get().progressId) })
      loadSource(0)
    },

    reload: () => {
      const { kind, item, tv, anime, serverIndex } = get()
      if (!item) return
      if (kind === 'tmdb') get().playTmdb(item, tv, serverIndex)
      else if (anime) get().playAnime(item, anime.details, anime.episode, anime.serverIndex, anime.slugs)
    },

    hasNext: () => {
      const { kind, tv, anime, item } = get()
      if (kind === 'anime' && anime) {
        const i = anime.details.episodes.findIndex(e => e.number === anime.episode.number)
        return i >= 0 && i + 1 < anime.details.episodes.length
      }
      if (!tv || item?.type !== 'tv') return false
      const season = tv.seasons.find(s => s.seasonNumber === tv.season)
      if (season && tv.episode < season.episodeCount) return true
      return tv.seasons.some(s => s.seasonNumber > tv.season && s.episodeCount > 0)
    },

    next: () => {
      const { kind, tv, anime, item, serverIndex } = get()
      if (!item || !get().hasNext()) return
      if (kind === 'anime' && anime) {
        const i = anime.details.episodes.findIndex(e => e.number === anime.episode.number)
        get().playAnime(item, anime.details, anime.details.episodes[i + 1], anime.serverIndex, anime.slugs)
        return
      }
      if (!tv) return
      const season = tv.seasons.find(s => s.seasonNumber === tv.season)
      const nextTv = season && tv.episode < season.episodeCount
        ? { ...tv, episode: tv.episode + 1, episodeTitle: null }
        : { ...tv, season: tv.seasons.filter(s => s.seasonNumber > tv.season && s.episodeCount > 0).sort((a, b) => a.seasonNumber - b.seasonNumber)[0].seasonNumber, episode: 1, episodeTitle: null }
      get().playTmdb(item, nextTv, serverIndex)
    },

    close: () => set({ ...resetPlayback(), open: false })
  }
})

window.vela?.on('embed-sniffed', s => usePlayer.getState().adoptSniffed(s.url, s.referer))

export function recordProgress(id: string, position: number, duration: number) {
  if (!id || !Number.isFinite(position) || !Number.isFinite(duration) || duration <= 0 || position < 0) return
  useLibrary.getState().saveProgress({ id, position, duration, lastWatchedAt: new Date().toISOString(), completed: position / duration >= 0.95 })
}
