// Saved-data sync document and merge, shared rules with iOS
// (Services/Link/SyncEngine.swift). The document doubles as each device's
// change log: every record carries the time it last changed (`at`) and
// deletions are kept as tombstones, so merging is commutative, idempotent and
// safe to repeat after an interrupted transfer.
//
// Every record, watch progress included, is simply "newest change wins": if
// you delete a show on the PC at 1 pm and keep watching it on the phone at
// 2 pm, the show stays. Timestamps from the other device are first shifted by
// the measured clock difference between the two (see shiftDoc), so a device
// whose clock is off can't win or lose merges unfairly. (`epoch` is still
// carried in progress records for older builds but no longer decides merges.)

export const SYNC_VERSION = 1
export const TOMBSTONE_TTL_MS = 90 * 24 * 3600_000
export const CAPS = { favorites: 100, recents: 24, progress: 100, searches: 12 } as const
export const SYNCED_SETTINGS = ['credential', 'animeEnabled', 'seekInterval', 'cardSize', 'contentFilter'] as const
export const MAX_DOC_BYTES = 50 * 1024 * 1024
export type SyncedSetting = typeof SYNCED_SETTINGS[number]

interface Rec { at: number; del?: boolean }
export interface ServerRec extends Rec { id: string; name: string; base: string; pos: number }
export interface ItemRec extends Rec { key: string; item: Record<string, unknown> }
export interface ProgressRec extends Rec { id: string; position: number; duration: number; completed: boolean; watchedAt: number; epoch: number }
export interface SearchRec extends Rec { key: string; q: string }

export interface SyncDoc {
  v: number
  settings: Partial<Record<SyncedSetting, { v: unknown; at: number }>>
  servers: ServerRec[]
  animeServers: ServerRec[]
  favorites: ItemRec[]
  recents: ItemRec[]
  progress: ProgressRec[]
  searches: SearchRec[]
  animeSearches: SearchRec[]
}

export const emptyDoc = (): SyncDoc => ({ v: SYNC_VERSION, settings: {}, servers: [], animeServers: [], favorites: [], recents: [], progress: [], searches: [], animeSearches: [] })

const itemTie = (r: ItemRec) => `${r.item.resumeSeason ?? ''}:${r.item.resumeEpisode ?? ''}:${r.item.title ?? ''}`

function lww<T extends Rec>(a: T, b: T, tie: (r: T) => string): T {
  if (a.at !== b.at) return a.at > b.at ? a : b
  if (!!a.del !== !!b.del) return a.del ? a : b
  return tie(a) >= tie(b) ? a : b
}

export function mergeProgress(a: ProgressRec, b: ProgressRec): ProgressRec {
  return lww(a, b, r => String(Math.round(r.position)).padStart(12, '0'))
}

function mergeList<T extends Rec>(a: T[], b: T[], key: (r: T) => string, pick: (x: T, y: T) => T): T[] {
  const map = new Map<string, T>()
  for (const r of [...a, ...b]) {
    const k = key(r)
    const cur = map.get(k)
    map.set(k, cur ? pick(cur, r) : r)
  }
  return [...map.values()]
}

const normBase = (b: string) => b.trim().toLowerCase().replace(/\/+$/, '')

/** Two devices may add the same server under different ids; keep one. */
function dedupeServers(list: ServerRec[]): ServerRec[] {
  const keep = new Map<string, ServerRec>()
  for (const s of list) {
    if (s.del) continue
    const k = normBase(s.base)
    const cur = keep.get(k)
    if (!cur || s.id < cur.id) keep.set(k, s)
  }
  const winners = new Set([...keep.values()].map(s => s.id))
  return list.map(s => (s.del || winners.has(s.id) ? s : { ...s, del: true }))
}

function prune<T extends Rec>(list: T[], now: number): T[] {
  return list.filter(r => !r.del || now - r.at < TOMBSTONE_TTL_MS)
}

export function mergeDocs(a: SyncDoc, b: SyncDoc, now = Date.now()): SyncDoc {
  const settings: SyncDoc['settings'] = {}
  for (const k of SYNCED_SETTINGS) {
    const x = a.settings[k], y = b.settings[k]
    settings[k] = !x ? y : !y ? x : x.at !== y.at ? (x.at > y.at ? x : y) : (JSON.stringify(x.v) >= JSON.stringify(y.v) ? x : y)
    if (!settings[k]) delete settings[k]
  }
  const srv = (x: ServerRec[], y: ServerRec[]) => prune(dedupeServers(mergeList(x, y, r => r.id, (p, q) => lww(p, q, r => `${r.name}|${r.base}|${r.pos}`))), now)
  return {
    v: SYNC_VERSION,
    settings,
    servers: srv(a.servers, b.servers),
    animeServers: srv(a.animeServers, b.animeServers),
    favorites: prune(mergeList(a.favorites, b.favorites, r => r.key, (p, q) => lww(p, q, itemTie)), now),
    recents: prune(mergeList(a.recents, b.recents, r => r.key, (p, q) => lww(p, q, itemTie)), now),
    progress: prune(mergeList(a.progress, b.progress, r => r.id, mergeProgress), now),
    searches: prune(mergeList(a.searches, b.searches, r => r.key, (p, q) => lww(p, q, r => r.q)), now),
    animeSearches: prune(mergeList(a.animeSearches, b.animeSearches, r => r.key, (p, q) => lww(p, q, r => r.q)), now)
  }
}

/** `dest` becomes a copy of `source`; everything else it had is tombstoned. */
export function replaceWith(dest: SyncDoc, source: SyncDoc, now = Date.now()): SyncDoc {
  const kill = <T extends Rec>(mine: T[], theirs: T[], key: (r: T) => string, epoch?: boolean): T[] => {
    const keep = new Set(theirs.map(key))
    const gone = mine.filter(r => !r.del && !keep.has(key(r))).map(r => ({ ...r, del: true, at: now, ...(epoch ? { epoch: now } : {}) }))
    return [...theirs, ...gone]
  }
  const settings: SyncDoc['settings'] = {}
  for (const k of SYNCED_SETTINGS) {
    const s = source.settings[k]
    if (s) settings[k] = { v: s.v, at: Math.max(s.at, dest.settings[k]?.at ?? 0) + 1 }
  }
  return {
    v: SYNC_VERSION,
    settings,
    servers: kill(dest.servers, source.servers, r => r.id),
    animeServers: kill(dest.animeServers, source.animeServers, r => r.id),
    favorites: kill(dest.favorites, source.favorites, r => r.key),
    recents: kill(dest.recents, source.recents, r => r.key),
    progress: kill(dest.progress, source.progress, r => r.id, true),
    searches: kill(dest.searches, source.searches, r => r.key),
    animeSearches: kill(dest.animeSearches, source.animeSearches, r => r.key)
  }
}

// ── Validation of docs received from the network ─────────────────────
const num = (v: unknown) => typeof v === 'number' && Number.isFinite(v)
const s = (v: unknown, max = 2048) => typeof v === 'string' && v.length <= max
const okRec = (r: any) => r && typeof r === 'object' && num(r.at) && (r.del === undefined || typeof r.del === 'boolean')

export function validateDoc(raw: unknown): SyncDoc | null {
  const d = raw as Partial<SyncDoc> | null
  if (!d || typeof d !== 'object' || d.v !== SYNC_VERSION) return null
  const arr = <T>(v: unknown, ok: (r: any) => boolean, max: number): T[] | null =>
    v === undefined ? [] : Array.isArray(v) && v.length <= max && v.every(r => okRec(r) && ok(r)) ? (v as T[]) : null
  const server = (r: any) => s(r.id, 64) && s(r.name, 120) && s(r.base, 500) && /^https?:\/\//i.test(r.base) && num(r.pos)
  const item = (r: any) => s(r.key, 300) && r.item && typeof r.item === 'object' && (r.item.type === 'movie' || r.item.type === 'tv') && s(r.item.tmdbId, 300) && s(r.item.title, 500)
  const prog = (r: any) => s(r.id, 300) && num(r.position) && num(r.duration) && typeof r.completed === 'boolean' && num(r.watchedAt) && num(r.epoch)
  const search = (r: any) => s(r.key, 200) && s(r.q, 200)
  // Any malformed list rejects the whole document: a silently emptied list
  // would be harmless in a merge but destructive in a fresh copy.
  const lists = {
    servers: arr<ServerRec>(d.servers, server, 200),
    animeServers: arr<ServerRec>(d.animeServers, server, 200),
    favorites: arr<ItemRec>(d.favorites, item, 2000),
    recents: arr<ItemRec>(d.recents, item, 2000),
    progress: arr<ProgressRec>(d.progress, prog, 5000),
    searches: arr<SearchRec>(d.searches, search, 1000),
    animeSearches: arr<SearchRec>(d.animeSearches, search, 1000)
  }
  if (Object.values(lists).some(l => l === null)) return null
  const out: SyncDoc = { v: SYNC_VERSION, settings: {}, ...(lists as Omit<SyncDoc, 'v' | 'settings'>) }
  const st = d.settings ?? {}
  if (typeof st !== 'object') return null
  const sv = (k: SyncedSetting, ok: (v: unknown) => boolean) => {
    const e = (st as any)[k]
    if (e && num(e.at) && ok(e.v)) out.settings[k] = { v: e.v, at: e.at }
  }
  sv('credential', v => s(v, 400))
  sv('animeEnabled', v => typeof v === 'boolean')
  sv('seekInterval', v => [5, 10, 15, 30].includes(v as number))
  sv('cardSize', v => v === 'compact' || v === 'large')
  sv('contentFilter', v => v === 'all' || v === 'movie' || v === 'tv')
  return out
}

/** Progress lists after merge are capped by most recent watch. */
export function topProgress(list: ProgressRec[]) {
  return list.filter(p => !p.del).sort((a, b) => b.watchedAt - a.watchedAt).slice(0, CAPS.progress)
}

// ── Clock differences between devices ────────────────────────────────
// Timestamps below this are placeholders ("older than anything"), not times.
const shiftT = (t: number, d: number) => (t > 1e11 ? t + d : t)

/** Converts another device's timestamps to this device's clock (`d` = ms to add). */
export function shiftDoc(doc: SyncDoc, d: number): SyncDoc {
  if (!d || !Number.isFinite(d)) return doc
  const recs = <T extends Rec>(l: T[]): T[] => l.map(r => ({ ...r, at: shiftT(r.at, d) }))
  const settings: SyncDoc['settings'] = {}
  for (const k of SYNCED_SETTINGS) { const e = doc.settings[k]; if (e) settings[k] = { v: e.v, at: shiftT(e.at, d) } }
  return {
    ...doc,
    settings,
    servers: recs(doc.servers),
    animeServers: recs(doc.animeServers),
    favorites: recs(doc.favorites),
    recents: recs(doc.recents),
    progress: recs(doc.progress).map(p => ({ ...p, watchedAt: shiftT(p.watchedAt, d), epoch: shiftT(p.epoch, d) })),
    searches: recs(doc.searches),
    animeSearches: recs(doc.animeSearches)
  }
}

/** Over 50 MB: try dropping tombstones; if that isn't enough, leave it alone. */
export function compactIfHuge(doc: SyncDoc): SyncDoc {
  if (JSON.stringify(doc).length <= MAX_DOC_BYTES) return doc
  const live = <T extends Rec>(l: T[]) => l.filter(r => !r.del)
  const slim: SyncDoc = {
    ...doc,
    servers: live(doc.servers), animeServers: live(doc.animeServers), favorites: live(doc.favorites), recents: live(doc.recents),
    progress: live(doc.progress), searches: live(doc.searches), animeSearches: live(doc.animeSearches)
  }
  return JSON.stringify(slim).length <= MAX_DOC_BYTES ? slim : doc
}
