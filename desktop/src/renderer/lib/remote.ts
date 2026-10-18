// Remote playback: runs commands from a paired phone against the player
// store, and publishes live playback state back to every connected phone.
import type { AnimeEpisode, MediaItem } from '@shared/types'
import type { RemoteState } from '@shared/link'
import { usePlayer } from '@/stores/player'
import { useSettings } from '@/stores/settings'
import { imageUrl, itemKey, tmdb, type TvDetails } from '@/lib/tmdb'
import { seasonsOf } from '@/features/details/actions'
import { canonicalItem } from './sync'
import { useLibrary } from '@/stores/library'

// ── Native player handle (registered by <Player>) ────────────────────
export interface PlayerHandle {
  state(): { position: number; duration: number; playing: boolean } | null
  play(): void
  pause(): void
  toggle(): void
  seek(to: number): void
  skip(by: number): void
  captions(): { list: string[]; index: number }
  setCaption(index: number): void
}
let handle: PlayerHandle | null = null
export function registerPlayer(h: PlayerHandle) { handle = h; schedulePublish(); return () => { if (handle === h) handle = null } }

let embedCache: { position: number; duration: number; playing: boolean } | null = null

// ── State publishing ─────────────────────────────────────────────────
let rev = 0
let connectedCount = 0
export function setConnectedCount(n: number) { const was = connectedCount; connectedCount = n; if (n > was) publish() }

export function buildState(): RemoteState {
  const p = usePlayer.getState()
  const s = useSettings.getState()
  const servers = (p.kind === 'anime' ? s.animeServers : s.servers).map(x => x.name)
  const native = p.sources.length > 0
  const live = native ? handle?.state() ?? null : p.embedUrl ? embedCache : null
  const mode: RemoteState['mode'] = !p.open ? 'idle' : p.error ? 'error' : p.resolving ? 'loading' : native ? 'native' : p.embedUrl ? 'embed' : 'loading'
  return {
    rev: ++rev,
    open: p.open,
    session: p.open ? p.progressId : '',
    kind: p.kind,
    title: p.item?.title ?? '',
    subtitle: p.subtitle,
    poster: p.item?.posterPath ? imageUrl(p.item.posterPath, 'w500') : null,
    itemKey: p.item ? itemKey(p.item) : null,
    season: p.tv?.season ?? null,
    episode: p.tv?.episode ?? null,
    animeEpisode: p.anime?.episode.number ?? null,
    mode,
    playing: live?.playing ?? false,
    position: live?.position ?? 0,
    duration: live?.duration ?? 0,
    controllable: !!live,
    servers,
    serverIndex: p.serverIndex,
    sources: p.sources.map(x => ({ name: x.name, audio: x.audio ?? null, quality: x.quality ?? null })),
    sourceIndex: p.sourceIndex,
    hasNext: p.open && p.hasNext(),
    captions: native && handle ? handle.captions().list : [],
    captionIndex: native && handle ? handle.captions().index : -1,
    status: p.status,
    error: p.error
  }
}

export function publish(deviceId: string | null = null) {
  if (!connectedCount && deviceId === null) return
  window.vela.link.send(deviceId, { t: 'state', s: buildState() })
}

let pubTimer: ReturnType<typeof setTimeout> | undefined
function schedulePublish() { clearTimeout(pubTimer); pubTimer = setTimeout(() => publish(), 200) }
usePlayer.subscribe(schedulePublish)

// Ticks once a second while something is open: native time comes from the
// player handle, web players from the embed bridge in main.
if (location.hash.replace('#', '') !== 'settings') setInterval(async () => {
  const p = usePlayer.getState()
  if (!p.open) { embedCache = null; return }
  if (!p.sources.length && p.embedUrl) {
    try { embedCache = await window.vela.embed.state() } catch { embedCache = null }
  }
  publish()
}, 1000)

// ── Commands ─────────────────────────────────────────────────────────
const recent: string[] = []
/** Results of recent commands, so a retried command gets the same answer. */
const results = new Map<string, Promise<string | null>>()

/** Runs a command once; a retry with the same id replays the first result. */
export function runCommandOnce(cmd: Record<string, unknown>): Promise<string | null> {
  const id = typeof cmd.id === 'string' ? cmd.id.slice(0, 64) : ''
  if (id && results.has(id)) return results.get(id)!
  const r = runCommand(cmd).catch(err => (err as Error).message.replace(/^Error invoking remote method '[^']+': (Error: )?/, ''))
  if (id) {
    results.set(id, r)
    if (results.size > 200) results.delete(results.keys().next().value!)
  }
  return r
}
const isInt = (v: unknown) => Number.isInteger(v) && (v as number) >= 0 && (v as number) < 10_000
const isNum = (v: unknown) => typeof v === 'number' && Number.isFinite(v)

function toItem(raw: unknown): MediaItem | null {
  const r = raw as Record<string, unknown> | null
  if (!r || (r.type !== 'movie' && r.type !== 'tv') || typeof r.tmdbId !== 'string' || typeof r.title !== 'string' || r.tmdbId.length > 300) return null
  return canonicalItem(r) as unknown as MediaItem
}

function waitFor(pred: () => boolean, ms: number): Promise<boolean> {
  return new Promise(resolve => {
    const end = Date.now() + ms
    const tick = () => { if (pred()) resolve(true); else if (Date.now() > end) resolve(false); else setTimeout(tick, 100) }
    tick()
  })
}

/** This PC's Continue-watching entry for the item, if newer than the phone's. */
function newerLocalResume(item: MediaItem): MediaItem | null {
  const mine = useLibrary.getState().recents.find(r => r.type === item.type && r.tmdbId === item.tmdbId)
  if (!mine || mine.resumeEpisode == null || mine.resumeSeason == null) return null
  const theirs = Date.parse(String(item.updatedAt ?? '')) || 0
  const ours = Date.parse(String(mine.updatedAt ?? '')) || 0
  return ours > theirs ? mine : null
}

function serverIndex(names: string[], name: unknown, fallback: number) {
  if (typeof name === 'string') {
    const i = names.findIndex(n => n.toLowerCase() === name.toLowerCase())
    if (i >= 0) return i
  }
  return fallback < names.length ? fallback : 0
}

export async function runCommand(cmd: Record<string, unknown>): Promise<string | null> {
  const id = typeof cmd.id === 'string' ? cmd.id.slice(0, 64) : ''
  if (!id || recent.includes(id)) return 'duplicate'
  recent.push(id); if (recent.length > 200) recent.shift()

  const p = usePlayer.getState()
  const s = useSettings.getState()
  const sessionOk = p.open && cmd.session === p.progressId

  switch (cmd.action) {
    case 'play-tmdb': {
      const item = toItem(cmd.item)
      if (!item || item.tmdbId.startsWith('kai:')) return 'invalid item'
      const idx = serverIndex(s.servers.map(x => x.name), cmd.server, p.kind === 'tmdb' ? p.serverIndex : 0)
      window.vela.showMainWindow()
      if (item.type === 'movie') { usePlayer.getState().playTmdb(item, null, idx); return null }
      if (!isInt(cmd.season) || !isInt(cmd.episode)) return 'missing episode'
      const d = await tmdb<TvDetails>(`/tv/${item.tmdbId}`)
      let season = cmd.season as number, episode = cmd.episode as number
      let title = typeof cmd.episodeTitle === 'string' ? cmd.episodeTitle.slice(0, 300) : null
      // "Resume" from the phone: if this PC watched the show more recently,
      // its episode wins over the phone's (possibly not-yet-synced) one.
      const mine = cmd.resume === true ? newerLocalResume(item) : null
      if (mine) { season = mine.resumeSeason!; episode = mine.resumeEpisode!; title = mine.resumeTitle ?? null }
      usePlayer.getState().playTmdb(item, { seasons: seasonsOf(d), season, episode, episodeTitle: title }, idx)
      return null
    }
    case 'play-anime': {
      const item = toItem(cmd.item)
      const slug = typeof cmd.slug === 'string' && /^[\w.-]{1,200}$/.test(cmd.slug) ? cmd.slug : null
      const number = typeof cmd.episode === 'string' && /^[\d.]{1,8}$/.test(cmd.episode) ? cmd.episode : null
      const catalog = s.animeServers[0]
      if (!item || !slug || !number) return 'invalid anime command'
      if (!catalog || !s.animeEnabled) return 'Anime is turned off on this PC'
      const details = await window.vela.anime.details(catalog.base, slug)
      const mine = cmd.resume === true ? newerLocalResume({ ...item, tmdbId: 'kai:' + slug }) : null
      const ep: AnimeEpisode | undefined =
        (mine && details.episodes.find(e => Math.floor(Number(e.number)) === mine.resumeEpisode)) ||
        details.episodes.find(e => e.number === number)
      if (!ep) return 'Episode not found on this PC'
      window.vela.showMainWindow()
      const animeItem = { ...item, tmdbId: 'kai:' + slug, anime: true }
      usePlayer.getState().playAnime(animeItem, details, ep, 0)
      const idx = serverIndex(s.animeServers.map(x => x.name), cmd.server, 0)
      if (idx > 0) usePlayer.getState().selectServer(idx)
      return null
    }
    case 'stop':
      if (p.open) usePlayer.getState().close()
      return null
  }

  // Everything below acts on what is playing now; a command aimed at a
  // title or episode that has since changed is dropped, not replayed.
  if (!sessionOk) return 'stale'
  const native = p.sources.length > 0
  const transport = async (action: 'play' | 'pause' | 'toggle' | 'seek' | 'skip', value = 0) => {
    if (native && handle) {
      // Apply, then confirm the player really changed; retry once before
      // telling the phone it didn't work.
      const before = handle.state()
      if (!before) return 'The player isn’t ready yet'
      const target = action === 'seek' ? value : action === 'skip' ? Math.max(0, before.position + value) : 0
      const wantPlaying = action === 'play' ? true : action === 'pause' ? false : !before.playing
      const apply = () => {
        if (action === 'seek' || action === 'skip') handle!.seek(target)
        else if (wantPlaying) handle!.play()
        else handle!.pause()
      }
      const done = () => {
        const now = handle?.state()
        if (!now) return false
        if (action === 'seek' || action === 'skip') return Math.abs(now.position - Math.min(target, Math.max(0, now.duration - 0.5) || target)) < 2.5
        return now.playing === wantPlaying
      }
      for (let attempt = 0; attempt < 2; attempt++) {
        apply()
        if (await waitFor(done, 2500)) return null
      }
      return action === 'seek' || action === 'skip' ? 'The PC didn’t move to that point' : `The PC didn’t ${wantPlaying ? 'start playing' : 'pause'}`
    }
    if (p.embedUrl) return (await window.vela.embed.control(action, value)) ? null : 'This web player can’t be controlled remotely'
    return 'Nothing is playing yet'
  }
  switch (cmd.action) {
    case 'toggle': case 'play': case 'pause': return transport(cmd.action)
    case 'seek': return isNum(cmd.to) && (cmd.to as number) >= 0 ? transport('seek', cmd.to as number) : 'invalid seek'
    case 'skip': return isNum(cmd.by) && Math.abs(cmd.by as number) <= 600 ? transport('skip', cmd.by as number) : 'invalid skip'
    case 'next': if (!p.hasNext()) return 'No next episode'; p.next(); return null
    case 'source': if (!isInt(cmd.index) || !p.sources[cmd.index as number]) return 'invalid source'; p.selectSource(cmd.index as number); return null
    case 'caption': {
      if (!native || !handle) return 'Captions can only be changed in Vela’s own player'
      const i = cmd.index
      if (!Number.isInteger(i) || (i as number) < -1 || (i as number) >= handle.captions().list.length) return 'invalid caption'
      handle.setCaption(i as number)
      return null
    }
    case 'server': {
      const names = (p.kind === 'anime' ? s.animeServers : s.servers).map(x => x.name)
      const idx = serverIndex(names, cmd.name, isInt(cmd.index) ? (cmd.index as number) : p.serverIndex)
      p.selectServer(idx)
      return null
    }
  }
  return 'unknown command'
}
