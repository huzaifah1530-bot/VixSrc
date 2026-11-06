// SkipDB-first timestamp lookups, with TheIntroDB for TMDB TV and AniSkip
// for anime as fallbacks. Main process so requests carry a real User-Agent and stay
// out of the renderer's CORS rules. Every function resolves to [] on any
// failure: missing timestamps must never affect playback.
import type { SkipSegment } from '@shared/types'
import {
  aniSkipEpisode, aniSkipSegments, matchMalId, mergeSegmentSources, normTitle, parseKitsu, skipDbSegments, theIntroDbSegments, validSegments,
  type AnimeIdentity, type KitsuCandidate
} from '@shared/introSkip'

const UA = 'Vela (+https://github.com/huzaifah1530-bot/Vela)'
const HIT_TTL = 24 * 3600_000
/** "No data" is a real answer too, but submissions arrive over time. */
const MISS_TTL = 30 * 60_000

interface Entry<T> { at: number; ttl: number; value: T }
const cache = new Map<string, Entry<unknown>>()
const inflight = new Map<string, Promise<unknown>>()

function cached<T>(key: string, run: () => Promise<{ value: T; ttl: number } | null>, fallback: T): Promise<T> {
  const hit = cache.get(key) as Entry<T> | undefined
  if (hit && Date.now() - hit.at < hit.ttl) return Promise.resolve(hit.value)
  const pending = inflight.get(key) as Promise<T> | undefined
  if (pending) return pending
  const p = run()
    .then(r => {
      // Only successful answers (including "none") are cached; errors retry.
      if (r) { cache.set(key, { at: Date.now(), ttl: r.ttl, value: r.value }); return r.value }
      return fallback
    })
    .catch(() => fallback)
    .finally(() => inflight.delete(key))
  inflight.set(key, p)
  if (cache.size > 500) cache.delete(cache.keys().next().value!)
  return p
}

async function getJsonStatus(url: string, headers: Record<string, string> = {}): Promise<{ status: number; body: unknown }> {
  const res = await fetch(url, { headers: { 'User-Agent': UA, Accept: 'application/json', ...headers }, signal: AbortSignal.timeout(10_000) })
  const body = await res.json().catch(() => null)
  return { status: res.status, body }
}

/** Duration bucket: TheIntroDB/AniSkip pick a release version by length. */
const bucket = (d: number) => (d > 0 ? Math.round(d / 10) * 10 : 0)

/** Open, read-only SkipDB lookup. An error leaves the legacy provider available. */
export function skipDb(imdbId: string, season: number | null, episode: number | null, duration: number): Promise<SkipSegment[]> {
  if (!/^tt\d+$/.test(imdbId) || (season === null) !== (episode === null)) return Promise.resolve([])
  const d = bucket(duration)
  return cached(`skipdb:${imdbId}:${season ?? 'movie'}:${episode ?? ''}:${d}`, async () => {
    const q = new URLSearchParams({ imdb_id: imdbId })
    if (season !== null && episode !== null) { q.set('season', String(season)); q.set('episode', String(episode)) }
    if (d > 0) q.set('duration', String(Math.round(duration)))
    const { status, body } = await getJsonStatus(`https://api.skipdb.tv/api/segments?${q}`)
    if (status === 404) return { value: [], ttl: MISS_TTL }
    if (status !== 200) return null
    const segs = validSegments(skipDbSegments(body), duration)
    return { value: segs, ttl: segs.length ? HIT_TTL : MISS_TTL }
  }, [])
}

/** SkipDB's local catalogue can identify anime already covered by its data. */
export function skipDbAnimeId(identity: AnimeIdentity): Promise<string | null> {
  const title = identity.titles[0]
  const year = identity.aired?.slice(0, 4)
  if (!title || !year) return Promise.resolve(null)
  return cached(`skipdb:anime-id:${identity.type}:${year}:${normTitle(title)}`, async () => {
    const { status, body } = await getJsonStatus(`https://skipdb.tv/api/titles/search?q=${encodeURIComponent(title)}`)
    if (status !== 200) return null
    const local = (body as { local?: unknown })?.local
    const names = new Set(identity.titles.map(normTitle))
    const matches = (Array.isArray(local) ? local : []).filter((x: any) =>
      /^tt\d+$/.test(String(x?.imdb_id)) && String(x?.year) === year &&
      x?.mediaType === (identity.type === 'movie' ? 'movie' : 'series') && names.has(normTitle(String(x?.name ?? ''))))
    const ids = [...new Set(matches.map((x: any) => String(x.imdb_id)))]
    const value = ids.length === 1 ? ids[0] : null
    return { value, ttl: value ? HIT_TTL : MISS_TTL }
  }, null)
}

export async function tmdbAnimeId(identity: AnimeIdentity, credential: string): Promise<string | null> {
  const title = identity.titles[0]
  if (!title || !identity.aired || !credential.trim()) return null
  const get = async (path: string, query: Record<string, string> = {}) => {
    const url = new URL(`https://api.themoviedb.org/3${path}`)
    for (const [key, value] of Object.entries(query)) url.searchParams.set(key, value)
    const headers: Record<string, string> = { Accept: 'application/json' }
    if (credential.startsWith('eyJ') || credential.length > 60) headers.Authorization = `Bearer ${credential}`
    else url.searchParams.set('api_key', credential)
    const response = await fetch(url, { headers, signal: AbortSignal.timeout(10_000) })
    return response.ok ? response.json() : null
  }
  try {
    const media = identity.type === 'movie' ? 'movie' : 'tv'
    const search = await get(`/search/${media}`, { query: title }) as { results?: { id: number; name?: string; original_name?: string; title?: string; original_title?: string; first_air_date?: string; release_date?: string }[] } | null
    const names = new Set(identity.titles.map(normTitle))
    const matches = (search?.results ?? []).filter(x => (x.first_air_date ?? x.release_date) === identity.aired &&
      [x.name, x.original_name, x.title, x.original_title].some(name => name && names.has(normTitle(name))))
    if (matches.length !== 1) return null
    const ids = await get(`/${media}/${matches[0].id}/external_ids`) as { imdb_id?: unknown } | null
    return typeof ids?.imdb_id === 'string' && /^tt\d+$/.test(ids.imdb_id) ? ids.imdb_id : null
  } catch { return null }
}

// ── TheIntroDB ─────────────────────────────────────────────────────────
// The v4 API resolves `tmdb_id` server-side and reads season/episode in
// TMDB's own numbering for it (verified: One Piece TMDB S22E1100 maps to
// TVDB S22E15), so TMDB numbers are sent as-is rather than guessed into
// TVDB order. `duration_ms` picks the matching release version.
export function introDbTv(tmdbId: string, season: number, episode: number, duration: number): Promise<SkipSegment[]> {
  if (!/^\d+$/.test(tmdbId) || !Number.isInteger(season) || !Number.isInteger(episode) || season < 0 || episode < 0) return Promise.resolve([])
  const d = bucket(duration)
  return cached(`tidb:${tmdbId}:${season}:${episode}:${d}`, async () => {
    const q = new URLSearchParams({ tmdb_id: tmdbId, season: String(season), episode: String(episode) })
    if (d >= 300) q.set('duration_ms', String(Math.round(duration * 1000)))
    const { status, body } = await getJsonStatus(`https://api.theintrodb.org/v4/media?${q}`)
    if (status === 404) return { value: [], ttl: MISS_TTL }
    if (status !== 200) return null
    const o = body as { type?: unknown; season?: unknown; episode?: unknown } | null
    // Must be the episode we asked for, not a show-level or list body.
    if (!o || o.type !== 'tv' || o.season !== season || o.episode !== episode) return { value: [], ttl: MISS_TTL }
    const segs = theIntroDbSegments(body)
    return { value: segs, ttl: segs.length ? HIT_TTL : MISS_TTL }
  }, [])
}

export async function tvSkip(tmdbId: string, imdbId: string, season: number, episode: number, duration: number): Promise<SkipSegment[]> {
  const primary = await skipDb(imdbId, season, episode, duration)
  if (['intro', 'outro'].every(kind => primary.some(s => s.kind === kind))) return primary
  const fallback = await introDbTv(tmdbId, season, episode, duration)
  return mergeSegmentSources(duration, primary, fallback)
}

// ── AniSkip (via a verified MAL id) ────────────────────────────────────
const identityKey = (i: AnimeIdentity) => [i.type, i.aired, i.episodes ?? '', ...i.titles.map(normTitle).sort()].join('|')

async function kitsuCandidates(title: string): Promise<KitsuCandidate[] | null> {
  const q = new URLSearchParams({
    'filter[text]': title, 'page[limit]': '20', include: 'mappings',
    'fields[anime]': 'canonicalTitle,titles,abbreviatedTitles,subtype,startDate,episodeCount,mappings',
    'fields[mappings]': 'externalSite,externalId'
  })
  const { status, body } = await getJsonStatus(`https://kitsu.io/api/edge/anime?${q}`, { Accept: 'application/vnd.api+json' })
  return status === 200 ? parseKitsu(body) : null
}

/** MAL id + the matching Kitsu entry, or null when not exactly one match. */
function malFor(identity: AnimeIdentity): Promise<{ malId: number; candidate: KitsuCandidate } | null> {
  return cached(`mal:${identityKey(identity)}`, async () => {
    const queries = [...new Set(identity.titles.map(t => t.replace(/\((tv|ona|ova)\)\s*$/i, '').trim()).filter(Boolean))].slice(0, 3)
    const all: KitsuCandidate[] = []
    let answered = false
    for (const q of queries) {
      const found = await kitsuCandidates(q)
      if (found) { answered = true; all.push(...found) }
      const id = matchMalId(identity, all)
      if (id) return { value: { malId: id, candidate: all.find(c => c.malId === id)! }, ttl: HIT_TTL }
    }
    return answered ? { value: null, ttl: MISS_TTL } : null
  }, null)
}

export async function aniSkip(identity: AnimeIdentity, episode: string, duration: number): Promise<SkipSegment[]> {
  const mal = await malFor(identity)
  if (!mal) return []
  const ep = aniSkipEpisode(episode, identity, mal.candidate)
  if (ep === null) return []
  const d = duration > 0 ? Math.round(duration) : 0
  return cached(`aniskip:${mal.malId}:${ep}:${bucket(d)}`, async () => {
    // `episodeLength` lets AniSkip pick timestamps submitted for this cut.
    const url = `https://api.aniskip.com/v2/skip-times/${mal.malId}/${ep}?types[]=op&types[]=ed&episodeLength=${d}`
    const { status, body } = await getJsonStatus(url)
    if (status === 404) return { value: [], ttl: MISS_TTL }
    if (status !== 200) return null
    const segs = aniSkipSegments(body)
    return { value: segs, ttl: segs.length ? HIT_TTL : MISS_TTL }
  }, [])
}
