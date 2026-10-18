// Desktop side of saved-data sync: keeps a local SyncDoc that mirrors the
// zustand stores (stamping each change), and applies merged docs back.
import type { MediaItem, StreamServer, WatchProgress } from '@shared/types'
import {
  CAPS, SYNCED_SETTINGS, emptyDoc, mergeDocs, replaceWith, topProgress,
  type ItemRec, type ProgressRec, type SearchRec, type ServerRec, type SyncDoc
} from '@shared/sync'
import { useLibrary } from '@/stores/library'
import { useSettings } from '@/stores/settings'

const KEY = 'vela_sync_doc'
const RESET_BACKWARD_S = 30

const isoNoMs = (v: unknown) => {
  if (typeof v !== 'string' && typeof v !== 'number') return null
  const d = new Date(v)
  return Number.isNaN(d.getTime()) ? null : d.toISOString().replace(/\.\d{3}Z$/, 'Z')
}

/** The fields both apps understand, in a fixed order. */
export function canonicalItem(i: MediaItem | Record<string, any>): Record<string, unknown> {
  return {
    tmdbId: String(i.tmdbId), type: i.type, title: String(i.title ?? ''), description: String(i.description ?? ''),
    posterPath: i.posterPath ?? null, backdropPath: i.backdropPath ?? null,
    rating: typeof i.rating === 'number' ? i.rating : null, year: String(i.year ?? ''),
    popularity: typeof i.popularity === 'number' ? i.popularity : 0,
    resumeSeason: i.resumeSeason ?? null, resumeEpisode: i.resumeEpisode ?? null, resumeTitle: i.resumeTitle ?? null,
    updatedAt: isoNoMs(i.updatedAt), anime: i.anime ?? null
  }
}

const itemKey = (i: { type: string; tmdbId: string }) => `${i.type}:${i.tmdbId}`
const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b)

export function loadDoc(): SyncDoc | null {
  try { const raw = localStorage.getItem(KEY); return raw ? (JSON.parse(raw) as SyncDoc) : null } catch { return null }
}
function saveDoc(doc: SyncDoc) { localStorage.setItem(KEY, JSON.stringify(doc)) }

/** Rebuilds the doc from the stores, keeping timestamps for unchanged records. */
export function docFromState(prev: SyncDoc | null, now = Date.now()): SyncDoc {
  const first = !prev
  const p = prev ?? emptyDoc()
  const s = useSettings.getState(), l = useLibrary.getState()
  const doc = emptyDoc()

  for (const k of SYNCED_SETTINGS) {
    const v = s[k]
    const old = p.settings[k]
    doc.settings[k] = old && same(old.v, v) ? old : { v, at: first ? 1 : now }
  }

  const servers = (cur: StreamServer[], old: ServerRec[]): ServerRec[] => {
    const byId = new Map(old.map(r => [r.id, r]))
    const out: ServerRec[] = cur.map((x, pos) => {
      const o = byId.get(x.id)
      const rec = { id: x.id, name: x.name, base: x.base, pos }
      return o && !o.del && o.name === rec.name && o.base === rec.base && o.pos === pos ? o : { ...rec, at: first ? 1 : now }
    })
    const live = new Set(cur.map(x => x.id))
    for (const o of old) if (!live.has(o.id)) out.push(o.del ? o : { ...o, del: true, at: now })
    return out
  }
  doc.servers = servers(s.servers, p.servers)
  doc.animeServers = servers(s.animeServers, p.animeServers)

  const items = (cur: MediaItem[], old: ItemRec[], cap: number): ItemRec[] => {
    const byKey = new Map(old.map(r => [r.key, r]))
    const out: ItemRec[] = cur.map(i => {
      const key = itemKey(i), item = canonicalItem(i), o = byKey.get(key)
      // Compare canonical forms: items merged in from iOS may omit null keys.
      if (o && !o.del && same(canonicalItem(o.item), item)) return o
      const stamp = first ? (Date.parse(String(i.updatedAt ?? '')) || 1) : now
      return { key, item, at: stamp }
    })
    const live = new Set(out.map(r => r.key))
    const trimming = cur.length >= cap // removals at the cap are trims, not deletes
    for (const o of old) {
      if (live.has(o.key)) continue
      if (o.del) out.push(o)
      else if (!trimming) out.push({ ...o, del: true, at: now })
    }
    return out
  }
  doc.favorites = items(l.favorites, p.favorites, CAPS.favorites)
  doc.recents = items(l.recents, p.recents, CAPS.recents)

  const byId = new Map(p.progress.map(r => [r.id, r]))
  doc.progress = l.watchProgress.map((w): ProgressRec => {
    const o = byId.get(w.id)
    const watchedAt = Date.parse(w.lastWatchedAt) || now
    if (o && !o.del && o.position === w.position && o.duration === w.duration && o.completed === w.completed) return o
    let epoch = o?.epoch ?? 0
    // Explicit restart, backward seek or un-completing starts a new epoch so
    // stale, further-along progress from another device can't win.
    if (o && !o.del && !first && (w.position < o.position - RESET_BACKWARD_S || (o.completed && !w.completed))) epoch = now
    return { id: w.id, position: w.position, duration: w.duration, completed: w.completed, watchedAt, epoch, at: first ? watchedAt : now }
  })
  const liveP = new Set(l.watchProgress.map(w => w.id))
  const trimP = l.watchProgress.length >= CAPS.progress
  for (const o of p.progress) {
    if (liveP.has(o.id)) continue
    if (o.del) doc.progress.push(o)
    else if (!trimP) doc.progress.push({ ...o, del: true, at: now, epoch: now })
  }

  const searches = (cur: string[], old: SearchRec[]): SearchRec[] => {
    const byKey = new Map(old.map(r => [r.key, r]))
    const out: SearchRec[] = cur.map((q, i) => {
      const key = q.toLowerCase(), o = byKey.get(key)
      return o && !o.del && o.q === q ? o : { key, q, at: first ? cur.length - i : now }
    })
    const live = new Set(out.map(r => r.key))
    const trimming = cur.length >= CAPS.searches
    for (const o of old) if (!live.has(o.key)) { if (o.del) out.push(o); else if (!trimming) out.push({ ...o, del: true, at: now }) }
    return out
  }
  doc.searches = searches(l.searchHistory, p.searches)
  doc.animeSearches = searches(l.animeSearchHistory, p.animeSearches)
  return doc
}

const alive = <T extends { del?: boolean }>(l: T[]) => l.filter(r => !r.del)

/** Writes a doc's live records into the stores. */
function applyToStores(doc: SyncDoc) {
  const toServers = (l: ServerRec[]) => alive(l).sort((a, b) => a.pos - b.pos || (a.id < b.id ? -1 : 1)).map(r => ({ id: r.id, name: r.name, base: r.base }))
  const patch: Record<string, unknown> = {}
  for (const k of SYNCED_SETTINGS) if (doc.settings[k]) patch[k] = doc.settings[k]!.v
  const servers = toServers(doc.servers)
  const animeServers = toServers(doc.animeServers)
  if (servers.length) patch.servers = servers
  patch.animeServers = animeServers
  useSettings.getState().set(patch)

  const items = (l: ItemRec[], cap: number) => alive(l).sort((a, b) => b.at - a.at).slice(0, cap).map(r => ({ ...(r.item as unknown as MediaItem) }))
  const searches = (l: SearchRec[]) => alive(l).sort((a, b) => b.at - a.at).slice(0, CAPS.searches).map(r => r.q)
  useLibrary.getState().replaceAll({
    favorites: items(doc.favorites, CAPS.favorites),
    recents: items(doc.recents, CAPS.recents).sort((a, b) => String(b.updatedAt ?? '').localeCompare(String(a.updatedAt ?? ''))),
    watchProgress: topProgress(doc.progress).map((p): WatchProgress => ({
      id: p.id, position: p.position, duration: p.duration, completed: p.completed, lastWatchedAt: new Date(p.watchedAt).toISOString()
    })),
    searchHistory: searches(doc.searches),
    animeSearchHistory: searches(doc.animeSearches)
  })
}

// ── Public API ────────────────────────────────────────────────────────
// Only the main window owns the sync doc; the Settings window just edits the
// stores, which reach the main window through the storage event.
const isMain = location.hash.replace('#', '') !== 'settings'

let current: SyncDoc = (() => {
  const d = docFromState(loadDoc())
  if (isMain) saveDoc(d)
  return d
})()
const listeners = new Set<(d: SyncDoc) => void>()

export const localDoc = () => current
export const onLocalChange = (cb: (d: SyncDoc) => void) => { listeners.add(cb); return () => listeners.delete(cb) }

function refresh() {
  const next = docFromState(current)
  if (same(next, current)) return
  current = next
  saveDoc(current)
  listeners.forEach(cb => cb(current))
}

let timer: ReturnType<typeof setTimeout> | undefined
const schedule = () => { clearTimeout(timer); timer = setTimeout(refresh, 800) }
if (isMain) useLibrary.subscribe(schedule)
if (isMain) useSettings.subscribe((s, prev) => { if (SYNCED_SETTINGS.some(k => s[k] !== prev[k]) || s.servers !== prev.servers || s.animeServers !== prev.animeServers) schedule() })

/** Merges a remote doc into ours and applies it. Returns the merged doc. */
export function mergeRemote(remote: SyncDoc): SyncDoc {
  clearTimeout(timer)
  refresh() // capture any pending local edit first
  const merged = mergeDocs(current, remote)
  applyToStores(merged)
  current = docFromState(merged)
  // Anything the stores dropped (caps) stays in the doc as-is.
  current = mergeDocs(current, merged)
  saveDoc(current)
  return current
}

/** Fresh copy: this device becomes a copy of `source`. */
export function replaceFromRemote(source: SyncDoc): SyncDoc {
  clearTimeout(timer)
  refresh()
  const replaced = replaceWith(current, source)
  applyToStores(replaced)
  current = mergeDocs(docFromState(replaced), replaced)
  saveDoc(current)
  return current
}
