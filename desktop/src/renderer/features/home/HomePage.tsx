import { useEffect, useMemo, useState } from 'react'
import { create } from 'zustand'
import type { MediaItem, MediaRow } from '@shared/types'
import { Grid, Row, SkeletonRows, Spinner, StatusCard } from '@/components/Media'
import { Hero } from './Hero'
import { loadHomeRows, searchTmdb } from '@/lib/tmdb'
import { homeRecents, useLibrary } from '@/stores/library'
import { useSettings } from '@/stores/settings'
import { useNav, useRefresh, useSearch } from '@/stores/ui'
import { quickPlay } from '../details/actions'

interface CatalogState { rows: MediaRow[]; loading: boolean; error: string | null; loadedFor: string | null; load: (force?: boolean) => Promise<void> }

export const useCatalog = create<CatalogState>((set, get) => ({
  rows: [], loading: false, error: null, loadedFor: null,
  load: async force => {
    const { credential, animeEnabled } = useSettings.getState()
    const sig = `${credential}|${animeEnabled}`
    if (!force && (get().loading || get().loadedFor === sig)) return
    set({ loading: true, error: null })
    try {
      set({ rows: await loadHomeRows(animeEnabled), loading: false, loadedFor: sig })
    } catch (err) {
      set({ loading: false, error: (err as Error).message.replace(/^Error invoking remote method '[^']+': (Error: )?/, '') })
    }
  }
}))

export function useDebouncedSearch(query: string, run: (q: string) => Promise<MediaItem[]>, onDone: (q: string, n: number) => void) {
  const [results, setResults] = useState<MediaItem[]>([])
  const [busy, setBusy] = useState(false)
  useEffect(() => {
    const q = query.trim()
    if (q.length < 2) { setResults([]); setBusy(false); return }
    setBusy(true)
    let live = true
    const t = setTimeout(async () => {
      try {
        const r = await run(q)
        if (live) { setResults(r); onDone(q, r.length) }
      } catch { if (live) setResults([]) }
      if (live) setBusy(false)
    }, 450)
    return () => { live = false; clearTimeout(t) }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [query])
  return { results, busy }
}

export function HomePage() {
  const { rows, loading, error, load } = useCatalog()
  const filter = useSettings(s => s.contentFilter)
  const animeEnabled = useSettings(s => s.animeEnabled)
  const credential = useSettings(s => s.credential)
  const recents = useLibrary(s => s.recents)
  const addSearch = useLibrary(s => s.addSearch)
  const query = useSearch(s => s.query)
  const push = useNav(s => s.push)
  const refresh = useRefresh(s => s.token)

  useEffect(() => { load() }, [load, credential, animeEnabled])
  useEffect(() => { if (refresh) load(true) }, [refresh, load])

  const { results, busy } = useDebouncedSearch(query, q => searchTmdb(q, animeEnabled), (q, n) => { if (n) addSearch(q) })
  const open = (item: MediaItem) => push({ name: 'details', item })

  const shown = useMemo(() => {
    const cw = homeRecents(recents).filter(i => !animeEnabled || !i.anime)
    const all = cw.length ? [{ title: 'Continue watching', subtitle: 'Pick up where you left off', items: cw }, ...rows] : rows
    if (filter === 'all') return all
    return all.map(r => ({ ...r, items: r.items.filter(i => i.type === filter) })).filter(r => r.items.length)
  }, [rows, recents, filter, animeEnabled])

  if (query.trim().length >= 2) {
    return (
      <div className="page">
        <div className="page-head"><span className="eyebrow">Search</span><h2 className="page-title">Results for “{query.trim()}”</h2></div>
        {busy && !results.length ? <Spinner label="Searching TMDB…" /> : results.length ? <Grid items={results} onOpen={open} onPlay={quickPlay} /> : <StatusCard title="No matches" message="Try a different title or add the year." />}
      </div>
    )
  }

  return (
    <div className="page page-home">
      <Hero items={rows.flatMap(r => r.items).slice(0, 20)} />
      {error && <StatusCard title="Couldn’t load the catalogue" message={error} action={<button className="btn" onClick={() => load(true)}>Try again</button>} />}
      {loading && !rows.length ? <SkeletonRows /> : shown.map(r => (
        <Row key={r.title} row={r} onOpen={open} onPlay={quickPlay} showProgress={r.title === 'Continue watching'} />
      ))}
    </div>
  )
}
