// Watch Together on the desktop: owns the party connection, keeps this PC's
// player on the room timeline, and maps between the player store and the
// room's media. Personal choices (captions, Sub/Dub, quality, volume, the
// sync nudge) stay local.
import { create } from 'zustand'
import type { AnimeEpisode, MediaItem } from '@shared/types'
import { PartyCore, type ControlMode, type PartyMedia, type Peer } from '@shared/party'
import { PARTY_RELAY, PartyConnection, inviteLink, newIdentity, newInvite, parseInvite, type Invite } from '@shared/partyClient'
import { usePlayer } from '@/stores/player'
import { useSettings } from '@/stores/settings'
import { toast } from '@/stores/ui'
import { tmdb, type TvDetails } from '@/lib/tmdb'
import { seasonsOf } from '@/features/details/actions'
import { canonicalItem } from './sync'
import { partyHooks, playerHandle } from './remote'

interface PartyView {
  active: boolean
  status: 'connecting' | 'connected' | 'reconnecting' | 'closed'
  link: string
  peers: Peer[]
  me: string
  isHost: boolean
  hostId: string
  leader: string
  canControl: boolean
  canConfigure: boolean
  mode: ControlMode
  allowed: string[]
  waitForAll: boolean
  waitingOn: string[]
  /** Personal sync nudge in seconds (e.g. a dub that runs a little long). */
  offset: number
  panelOpen: boolean
  /** Viewer said "follow" once: keep following for the rest of the session. */
  following: boolean
  /** The host moved on; waiting for this viewer to choose. */
  prompt: { media: PartyMedia | null; title: string | null } | null
}

export const useParty = create<PartyView>(() => ({
  active: false, status: 'closed', link: '', peers: [], me: '', isHost: false, hostId: '', leader: '',
  canControl: true, canConfigure: false, mode: 'everyone', allowed: [], waitForAll: true,
  waitingOn: [], offset: 0, panelOpen: false, following: false, prompt: null
}))

let core: PartyCore | null = null
let conn: PartyConnection | null = null
let loop: ReturnType<typeof setInterval> | null = null
/** Media key we're loading because the room asked (not a local change). */
let loadingFromRoom: string | null = null
/** Don't hold the room while we reload for a personal choice (Sub/Dub, quality). */
let quietUntil = 0

const IDENTITY_KEY = 'vela_party_identity'
function identityFor(room: string) {
  // Same id + secret per room, so rejoining (or the host returning) keeps its role.
  const all = JSON.parse(localStorage.getItem(IDENTITY_KEY) ?? '{}') as Record<string, { peer: string; secret: string }>
  if (!all[room]) { all[room] = newIdentity(); localStorage.setItem(IDENTITY_KEY, JSON.stringify(all)) }
  return all[room]
}

function displayName() {
  const n = (useSettings.getState() as unknown as { partyName?: string }).partyName
  return n?.trim() || 'PC'
}

// ── Player ↔ room media ──────────────────────────────────────────────
/** Local media key → the room key it was loaded for (anime slugs differ by site). */
const aliases = new Map<string, string>()

export function currentMedia(): PartyMedia | null {
  const m = rawMedia()
  if (m && aliases.has(m.key)) m.key = aliases.get(m.key)!
  return m
}

function rawMedia(): PartyMedia | null {
  const p = usePlayer.getState()
  if (!p.open || !p.item) return null
  const s = useSettings.getState()
  if (p.kind === 'anime' && p.anime) {
    const slug = p.item.tmdbId.replace(/^kai:/, '')
    return { kind: 'anime', key: `anime:${slug}:${p.anime.episode.number}`, item: canonicalItem(p.item), slug, episode: p.anime.episode.number, title: p.item.title, server: s.animeServers[p.serverIndex]?.name ?? '' }
  }
  return {
    kind: 'tmdb', key: p.progressId, item: canonicalItem(p.item),
    season: p.tv?.season ?? null, episode: p.tv?.episode ?? null, episodeTitle: p.tv?.episodeTitle ?? null,
    server: s.servers[p.serverIndex]?.name ?? ''
  }
}

const byName = (list: { name: string }[], name: string) => Math.max(0, list.findIndex(x => x.name.toLowerCase() === name.toLowerCase()))

async function loadMedia(media: PartyMedia | null) {
  if (!media) return
  if (currentMedia()?.key === media.key) return
  loadingFromRoom = media.key
  const s = useSettings.getState()
  try {
    if (media.kind === 'tmdb') {
      const item = media.item as unknown as MediaItem
      if (item.type === 'movie') { usePlayer.getState().playTmdb(item, null, byName(s.servers, media.server)); return }
      const d = await tmdb<TvDetails>(`/tv/${item.tmdbId}`)
      usePlayer.getState().playTmdb(item, { seasons: seasonsOf(d), season: media.season ?? 1, episode: media.episode ?? 1, episodeTitle: media.episodeTitle ?? null }, byName(s.servers, media.server))
      return
    }
    const base = s.animeServers[byName(s.animeServers, media.server)]?.base ?? s.animeServers[0]?.base
    if (!base) { toast('Add an anime server in Settings to watch this'); return }
    // Slugs differ between sites: fall back to finding the show by title.
    let details = await window.vela.anime.details(base, media.slug).catch(() => null)
    if (!details) {
      const slug = await window.vela.anime.findSlug(base, media.title)
      details = slug ? await window.vela.anime.details(base, slug) : null
    }
    const ep: AnimeEpisode | undefined = details?.episodes.find(e => e.number === media.episode)
    if (!details || !ep) { core?.setLoading(true, 'Episode not available on this PC'); toast('This episode isn’t available on your anime server'); return }
    const item = { ...(media.item as unknown as MediaItem), tmdbId: 'kai:' + details.show.slug, anime: true }
    usePlayer.getState().playAnime(item, details, ep, byName(s.animeServers, media.server))
    const local = rawMedia()?.key
    if (local && local !== media.key) aliases.set(local, media.key)
  } catch (err) {
    toast('Couldn’t open what the party is watching: ' + (err as Error).message)
  } finally {
    setTimeout(() => { if (loadingFromRoom === media.key) loadingFromRoom = null }, 1500)
  }
}

/** The media after `current`, for the leader at the end of an episode. */
function nextMedia(current: PartyMedia): PartyMedia | null {
  const p = usePlayer.getState()
  if (currentMedia()?.key !== current.key || !p.hasNext()) return null
  if (current.kind === 'anime' && p.anime) {
    const i = p.anime.details.episodes.findIndex(e => e.number === p.anime!.episode.number)
    const next = p.anime.details.episodes[i + 1]
    return next ? { ...current, key: `anime:${current.slug}:${next.number}`, episode: next.number } : null
  }
  if (current.kind === 'tmdb' && p.tv) {
    const tv = p.tv
    const season = tv.seasons.find(s => s.seasonNumber === tv.season)
    const [s, e] = season && tv.episode < season.episodeCount
      ? [tv.season, tv.episode + 1]
      : [tv.seasons.filter(x => x.seasonNumber > tv.season && x.episodeCount > 0).sort((a, b) => a.seasonNumber - b.seasonNumber)[0]?.seasonNumber, 1]
    if (s == null) return null
    return { ...current, key: `tv:${(current.item as any).tmdbId}:${s}:${e}`, season: s, episode: e, episodeTitle: null }
  }
  return null
}

// ── View refresh ─────────────────────────────────────────────────────
function refresh() {
  if (!core || !conn) return
  const cfg = core.state?.cfg
  useParty.setState({
    status: conn.status,
    peers: [...core.peers.values()].sort((a, b) => a.joined - b.joined),
    me: core.me,
    isHost: core.isHost,
    hostId: cfg?.host ?? '',
    leader: core.leader,
    canControl: core.canControl(),
    canConfigure: core.canConfigure(),
    mode: cfg?.mode ?? 'everyone',
    allowed: cfg?.allowed ?? [],
    waitForAll: cfg?.waitForAll ?? true,
    waitingOn: core.waitingOn().map(p => p.name)
  })
}

// ── Sync loop ────────────────────────────────────────────────────────
async function syncOnce() {
  if (!core?.state) return
  const target = core.target()
  const quiet = Date.now() < quietUntil
  // The host is browsing: followers just wait.
  if (!target.media) { core.setLoading(false); core.tick(); return }
  if (currentMedia()?.key !== target.media.key) {
    // Waiting for this viewer to answer "follow the host?" — don't load.
    if (useParty.getState().prompt) { core.tick(); return }
    if (loadingFromRoom !== target.media.key) loadMedia(target.media)
    core.setLoading(true)
    core.tick()
    return
  }
  const p = usePlayer.getState()
  const offset = useParty.getState().offset
  const h = playerHandle()
  if (p.sources.length && h) {
    const st = h.state()
    if (!st) { core.setLoading(!quiet); core.tick(); return }
    core.setLoading(false)
    const ended = st.duration > 0 && st.position >= st.duration - 0.6
    const c = core.sync({ pos: st.position - offset, playing: st.playing, ended }, quiet)
    if (ended && c.play) { core.tick(); return } // the leader is moving the room on
    if (c.seek !== null) h.raw.seek(c.seek + offset)
    if (c.play && !st.playing) h.raw.play()
    if (!c.play && st.playing) h.raw.pause()
    h.raw.setRate(c.rate)
  } else if (p.embedUrl) {
    // Web players: no speed control, so only coarse corrections.
    const st = await window.vela.embed.state().catch(() => null)
    core.setLoading(!st && !quiet)
    if (st) {
      const c = core.sync({ pos: st.position - offset, playing: st.playing }, quiet)
      if (c.seek !== null) window.vela.embed.control('seek', c.seek + offset)
      if (c.play !== st.playing) window.vela.embed.control(c.play ? 'play' : 'pause')
    }
  } else {
    core.setLoading(!quiet)
  }
  core.tick()
}

function onStruggling() {
  // Step quality down within the same audio track, if there is one.
  const p = usePlayer.getState()
  const cur = p.sources[p.sourceIndex]
  const height = (q?: string) => Number(/(\d+)p/.exec(q ?? '')?.[1] ?? Infinity)
  const lower = p.sources
    .map((s, i) => ({ s, i }))
    .filter(x => x.s.audio === cur?.audio && height(x.s.quality) < height(cur?.quality))
    .sort((a, b) => height(b.s.quality) - height(a.s.quality))[0]
  if (lower) {
    quietUntil = Date.now() + 8000
    p.selectSource(lower.i)
    toast(`Your connection is struggling to keep up — switched to ${lower.s.quality}`)
  } else {
    toast('Your connection is struggling to keep up with the party')
  }
}

// Personal reloads (Sub/Dub, quality) don't hold the room.
usePlayer.subscribe((s, prev) => {
  if (!core) return
  if (s.progressId === prev.progressId && s.sourceIndex !== prev.sourceIndex) quietUntil = Date.now() + 8000
  const changed = s.open !== prev.open || s.progressId !== prev.progressId || s.item?.tmdbId !== prev.item?.tmdbId
  if (!changed || loadingFromRoom) return
  const media = s.open ? currentMedia() : null
  const roomKey = core.state?.tl.media?.key ?? null
  if ((media?.key ?? null) === roomKey) return
  if (core.isLeader) {
    // Host picked something else (or went back to browsing): the room
    // follows, starting where the host resumes rather than 0:00.
    core.setMedia(media, s.open ? s.resumeAt : 0)
  } else if (s.open || roomKey) {
    // A viewer going their own way leaves the party.
    leaveParty(true)
    toast('You left the watch party')
  }
})

/** Viewer's answer to "the host moved on — follow them?" */
export function answerFollow(follow: boolean) {
  const prompt = useParty.getState().prompt
  useParty.setState({ prompt: null, following: follow })
  if (!follow) { leaveParty(); return }
  // Remember it: coming back with the same link keeps following.
  if (conn) localStorage.setItem('vela_party_following_' + conn.invite.room, '1')
  if (prompt?.media) loadMedia(prompt.media)
  else if (usePlayer.getState().open) { loadingFromRoom = '(browsing)'; usePlayer.getState().close(); setTimeout(() => { loadingFromRoom = null }, 500) }
}

function onRoomMedia(media: PartyMedia | null, info: { initial: boolean; mine: boolean }) {
  if (info.mine) return
  const s = useParty.getState()
  if (info.initial || s.following) {
    if (media) loadMedia(media)
    else if (usePlayer.getState().open) { loadingFromRoom = '(browsing)'; usePlayer.getState().close(); setTimeout(() => { loadingFromRoom = null }, 500) }
    return
  }
  useParty.setState({ prompt: { media, title: media ? String((media.item as any).title ?? 'something else') + (media.kind === 'tmdb' && media.episode ? ` · S${media.season}E${media.episode}` : media.kind === 'anime' ? ` · E${media.episode}` : '') : null } })
}

// ── Public API ───────────────────────────────────────────────────────
function begin(invite: Invite, creating: boolean) {
  leaveParty(true)
  const id = identityFor(invite.room)
  conn = new PartyConnection(PARTY_RELAY, invite, id.peer, id.secret)
  core = new PartyCore(id.peer, displayName(), 'pc', conn, {
    onMedia: (m, _tl, info) => onRoomMedia(m, info),
    onChange: refresh,
    onToast: toast,
    onStruggling,
    nextMedia
  })
  conn.core = core
  conn.onStatus = () => {
    refresh()
    if (creating && conn?.status === 'connected' && !core?.state) {
      const p = usePlayer.getState()
      const h = playerHandle()?.state()
      core!.create(currentMedia(), h?.position ?? 0, h?.playing ?? false)
      if (p.open) toast('Watch party started — share the link')
    }
  }
  // Rejoining a party you've been in: you're following the host already.
  const rejoining = !creating && (!!localStorage.getItem('vela_party_following_' + invite.room) || !!JSON.parse(localStorage.getItem(IDENTITY_KEY) ?? '{}')[invite.room + ':seen'])
  useParty.setState({ active: true, link: inviteLink(invite), status: 'connecting', panelOpen: true, offset: 0, following: rejoining, prompt: null })
  const seen = JSON.parse(localStorage.getItem(IDENTITY_KEY) ?? '{}'); seen[invite.room + ':seen'] = true; localStorage.setItem(IDENTITY_KEY, JSON.stringify(seen))
  conn.open().catch(err => toast('Couldn’t start the party: ' + (err as Error).message))
  loop = setInterval(() => { syncOnce().catch(() => {}) }, 500)
  window.addEventListener('online', onNetwork)
}

function onNetwork() { conn?.networkChanged() }

export function startParty() { begin(newInvite(), true) }

export function joinParty(text: string) {
  const invite = parseInvite(text)
  if (!invite) { toast('That isn’t a Vela watch party link'); return false }
  begin(invite, false)
  return true
}

export function leaveParty(silent = false) {
  if (loop) clearInterval(loop)
  loop = null
  conn?.close()
  playerHandle()?.raw.setRate(1)
  window.removeEventListener('online', onNetwork)
  const was = !!core
  core = null
  conn = null
  useParty.setState({ active: false, status: 'closed', peers: [], panelOpen: false, waitingOn: [], prompt: null, following: false })
  if (was && !silent) toast('Left the watch party')
}

export const partyActive = () => !!core

partyHooks.start = () => startParty()
partyHooks.join = link => joinParty(link)
partyHooks.leave = () => leaveParty()
partyHooks.info = () => (core && conn ? { link: inviteLink(conn.invite), count: core.peers.size + 1 } : null)

// User actions from this PC's player (or the phone remote). Each returns
// true when handled by the party (the caller then mirrors it locally).
export const party = {
  play: () => (core ? core.play() : false),
  pause: () => (core ? core.pause() : false),
  toggle: () => (core ? (core.target().playing ? core.pause() : core.play()) : false),
  seek: (pos: number) => (core ? core.seek(pos - useParty.getState().offset) : false),
  skip: (by: number) => (core ? core.skip(by) : false),
  ended: () => { core?.ended() },
  configure: (patch: Parameters<PartyCore['configure']>[0]) => core?.configure(patch),
  toggleAllowed: (peer: string) => {
    if (!core?.state) return
    const allowed = core.state.cfg.allowed.includes(peer) ? core.state.cfg.allowed.filter(x => x !== peer) : [...core.state.cfg.allowed, peer]
    core.configure({ allowed })
  },
  nudge: (by: number) => useParty.setState(s => ({ offset: Math.round((s.offset + by) * 10) / 10 }))
}
