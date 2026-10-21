// Intro skipping: one segment model for every timestamp source, the
// validation applied to all of them, the strict anime → MAL identity match,
// and the auto-skip state machine. Pure code, shared by main (fetching) and
// the renderer (player); iOS mirrors it in Models/SkipSegment.swift.
//
// Sources, in priority order:
//   stream     - timestamps the anime host ships with the stream (MegaPlay `intro`/`outro`)
//   aniskip    - api.aniskip.com v2, by verified MAL id + episode number
//   theintrodb - api.theintrodb.org v4, by TMDB id + TMDB season/episode
import type { SkipSegment } from './types'

/** Longest plausible intro; anything longer is treated as bad data. */
const MAX_INTRO_SECONDS = 600
const MIN_SEGMENT_SECONDS = 3

const finite = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v)

/**
 * Keeps a segment only if it makes sense for this video. `duration` is the
 * real video length in seconds (0 when unknown). Returns a clamped copy.
 */
export function validSegment(s: SkipSegment, duration: number): SkipSegment | null {
  if (!finite(s.start) || !finite(s.end) || s.start < 0) return null
  let end = s.end
  if (duration > 0) {
    if (s.start >= duration - MIN_SEGMENT_SECONDS) return null
    if (end > duration + 2) return null
    end = Math.min(end, duration)
  }
  if (end - s.start < MIN_SEGMENT_SECONDS) return null
  if (s.kind === 'intro' && end - s.start > MAX_INTRO_SECONDS) return null
  return { ...s, end }
}

export function validSegments(list: SkipSegment[], duration: number): SkipSegment[] {
  const out: SkipSegment[] = []
  for (const s of list) {
    const v = validSegment(s, duration)
    if (v && !out.some(o => o.kind === v.kind && Math.abs(o.start - v.start) < 1)) out.push(v)
  }
  return out.sort((a, b) => a.start - b.start)
}

// ── Source parsers ──────────────────────────────────────────────────────

/** MegaPlay / VidTube getSources: `intro: {start, end}` in seconds; 0/0 = none. */
export function streamSegments(json: unknown): SkipSegment[] {
  const out: SkipSegment[] = []
  const o = json && typeof json === 'object' ? json as Record<string, unknown> : {}
  for (const [key, kind] of [['intro', 'intro'], ['outro', 'outro']] as const) {
    const r = o[key] as { start?: unknown; end?: unknown } | undefined
    const start = Number(r?.start), end = Number(r?.end)
    if (finite(start) && finite(end) && end > start) out.push({ kind, start, end, source: 'stream' })
  }
  return out
}

/**
 * TheIntroDB v4 GET /media body. Times are ms; `start_ms: null` means the
 * start of the video, `end_ms: null` the end. Only intros (skippable) and
 * credits (kept for a future "skip credits") are taken; an intro without
 * an end isn't an intro.
 */
export function theIntroDbSegments(body: unknown): SkipSegment[] {
  const o = body && typeof body === 'object' ? body as Record<string, unknown> : {}
  const out: SkipSegment[] = []
  const take = (field: string, kind: SkipSegment['kind']) => {
    const list = Array.isArray(o[field]) ? o[field] as { start_ms?: unknown; end_ms?: unknown }[] : []
    for (const r of list) {
      const start = r?.start_ms == null ? 0 : Number(r.start_ms)
      if (r?.end_ms == null) continue
      const end = Number(r.end_ms)
      if (finite(start) && finite(end)) out.push({ kind, start: start / 1000, end: end / 1000, source: 'theintrodb' })
    }
  }
  take('intro', 'intro')
  take('credits', 'outro')
  return out
}

/**
 * AniSkip v2 /skip-times body. `op` is the opening; `ed` is kept as an
 * outro. `mixed-op` (opening over story) is deliberately not requested.
 */
export function aniSkipSegments(body: unknown): SkipSegment[] {
  const o = body && typeof body === 'object' ? body as { found?: unknown; results?: unknown } : {}
  if (o.found !== true || !Array.isArray(o.results)) return []
  const out: SkipSegment[] = []
  for (const r of o.results as { skipType?: unknown; interval?: { startTime?: unknown; endTime?: unknown } }[]) {
    const kind = r?.skipType === 'op' ? 'intro' : r?.skipType === 'ed' ? 'outro' : null
    const start = Number(r?.interval?.startTime), end = Number(r?.interval?.endTime)
    if (kind && finite(start) && finite(end)) out.push({ kind, start, end, source: 'aniskip' })
  }
  return out
}

// ── Anime identity (catalogue page → MAL id via Kitsu mappings) ─────────

/** What an AnimeKai/AniKoto watch page says about the show. */
export interface AnimeIdentity {
  /** Heading, data-jp and the `.names` synonyms. */
  titles: string[]
  /** Normalised: tv | movie | ova | ona | special | music */
  type: string
  /** First air date, YYYY-MM-DD. */
  aired: string | null
  /** Episode total the page states, if any. */
  episodes: number | null
}

export interface KitsuCandidate {
  malId: number | null
  titles: string[]
  subtype: string
  startDate: string | null
  episodeCount: number | null
}

export function normTitle(t: string): string {
  return t.normalize('NFKD').replace(/[\u0300-\u036f]/g, '').toLowerCase()
    .replace(/\((tv|ona|ova)\)\s*$/, '')
    .replace(/[^a-z0-9]+/g, ' ').trim()
}

export function normType(t: string): string {
  const s = t.trim().toLowerCase()
  if (s === 'tv special') return 'special'
  return ['tv', 'movie', 'ova', 'ona', 'special', 'music'].includes(s) ? s : ''
}

const MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec']
/** "Oct 3, 2020 to Mar 27, 2021" → "2020-10-03". Needs a full day. */
export function parseAired(text: string): string | null {
  const m = /([A-Za-z]{3})[a-z]*\.?\s+(\d{1,2}),\s*(\d{4})/.exec(text)
  if (!m) return null
  const month = MONTHS.indexOf(m[1].toLowerCase())
  if (month < 0) return null
  return `${m[3]}-${String(month + 1).padStart(2, '0')}-${m[2].padStart(2, '0')}`
}

const dayDiff = (a: string, b: string) => Math.abs(Date.parse(a + 'T00:00:00Z') - Date.parse(b + 'T00:00:00Z')) / 86_400_000

/**
 * The MAL id for this catalogue show, or null. Not a fuzzy match: a
 * candidate must share an exact (normalised) title, the same type and the
 * same first air date (±1 day for time zones), and agree on the episode
 * count when both know it. Anything other than exactly one MAL id is
 * rejected, so separate seasons, cours and specials never get mixed up.
 */
export function matchMalId(identity: AnimeIdentity, candidates: KitsuCandidate[]): number | null {
  const titles = new Set(identity.titles.map(normTitle).filter(Boolean))
  if (!titles.size || !identity.type || !identity.aired) return null
  const ids = new Set<number>()
  for (const c of candidates) {
    if (!c.malId || !c.startDate) continue
    if (normType(c.subtype) !== identity.type) continue
    if (!Number.isFinite(dayDiff(c.startDate, identity.aired)) || dayDiff(c.startDate, identity.aired) > 1) continue
    if (identity.episodes && c.episodeCount && identity.episodes !== c.episodeCount) continue
    if (!c.titles.some(t => titles.has(normTitle(t)))) continue
    ids.add(c.malId)
  }
  return ids.size === 1 ? [...ids][0] : null
}

/** The AniSkip episode number, or null when it can't be trusted. */
export function aniSkipEpisode(episode: string, identity: AnimeIdentity, candidate: KitsuCandidate | null): number | null {
  if (!/^\d+$/.test(episode.trim())) return null // 12.5 recaps etc.
  const n = Number(episode)
  if (n < 1) return null
  // Absolute numbering past this entry's length means a different MAL entry.
  const total = candidate?.episodeCount ?? identity.episodes
  if (total && n > total) return null
  return n
}

export function parseKitsu(body: unknown): KitsuCandidate[] {
  const o = body && typeof body === 'object' ? body as { data?: unknown; included?: unknown } : {}
  const mal = new Map<string, number>()
  for (const inc of Array.isArray(o.included) ? o.included as any[] : []) {
    if (inc?.type === 'mappings' && inc.attributes?.externalSite === 'myanimelist/anime') {
      const id = Number(inc.attributes.externalId)
      if (Number.isInteger(id) && id > 0) mal.set(String(inc.id), id)
    }
  }
  return (Array.isArray(o.data) ? o.data as any[] : []).map(d => {
    const a = d?.attributes ?? {}
    const links = Array.isArray(d?.relationships?.mappings?.data) ? d.relationships.mappings.data as { id: string }[] : []
    const malIds = links.map(l => mal.get(String(l.id))).filter((x): x is number => !!x)
    const titles = [a.canonicalTitle, ...Object.values(a.titles ?? {}), ...(Array.isArray(a.abbreviatedTitles) ? a.abbreviatedTitles : [])]
      .filter((t): t is string => typeof t === 'string' && !!t.trim())
    return {
      malId: new Set(malIds).size === 1 ? malIds[0] : null,
      titles,
      subtype: String(a.subtype ?? ''),
      startDate: typeof a.startDate === 'string' ? a.startDate : null,
      episodeCount: Number.isInteger(a.episodeCount) && a.episodeCount > 0 ? a.episodeCount : null
    }
  })
}

// ── Playback ────────────────────────────────────────────────────────────

/** The intro the playhead is in (and not in its last second), if any. */
export function activeIntro(segments: SkipSegment[], t: number): SkipSegment | null {
  return segments.find(s => s.kind === 'intro' && t >= s.start && t < s.end - 1) ?? null
}

export const segmentKey = (episodeKey: string, s: SkipSegment) => `${episodeKey}|${Math.round(s.start)}`

/**
 * Decides when automatic skipping fires. Each intro fires at most once per
 * episode (`handled` survives source switches and reloads), and only when
 * playback runs into it: when the playhead reaches it by normal playback,
 * or when playback begins inside it. Seeking or rewinding into an intro
 * marks it handled without jumping, so viewers can watch it if they want.
 */
export class AutoSkipTracker {
  private last: number | null = null
  private fresh = true
  constructor(private readonly handled: Set<string>) {}

  /** New source or newly arrived timestamps: the next tick counts as a start. */
  restart() { this.last = null; this.fresh = true }

  /**
   * Call on every time update. Returns the time to seek to, or null.
   * `allowed` = setting on and (not in a party, or this device is the host).
   */
  step(episodeKey: string, segments: SkipSegment[], t: number, allowed: boolean): number | null {
    const prev = this.last
    const fresh = this.fresh
    this.last = t
    this.fresh = false
    const intro = activeIntro(segments, t)
    if (!intro) return null
    const key = segmentKey(episodeKey, intro)
    if (this.handled.has(key)) return null
    // Normal playback = small forward step since the last tick.
    const natural = prev !== null && t >= prev && t - prev <= 2
    const enteredByPlaying = natural && prev! < intro.start + 2
    const started = fresh || prev === null
    if (!enteredByPlaying && !started) {
      // Seeked or rewound into it: leave it alone from now on.
      if (!natural) this.handled.add(key)
      return null
    }
    this.handled.add(key)
    return allowed ? intro.end : null
  }
}
