import { useEffect, useState } from 'react'
import { create } from 'zustand'
import type { AnimeShow, MediaItem, MediaRow } from '@shared/types'
import { Icon } from '@/components/Icon'
import { Grid, Row, SkeletonRows, Spinner, StatusCard } from '@/components/Media'
import { animeRecents, useIsFavorite, useLibrary } from '@/stores/library'
import { useSettings } from '@/stores/settings'
import { toast, useNav, useRefresh, useSearch } from '@/stores/ui'
import { usePlayer } from '@/stores/player'
import { useDebouncedSearch } from '../home/HomePage'
import { cx } from '@/lib/format'
import { animeSlug } from '@/lib/tmdb'

/** Anime-catalogue titles are stored as `kai:<slug>` MediaItems, like iOS. */
export function animeItem(show: AnimeShow, description = ''): MediaItem {
  const counts = [show.subCount ? `Sub ${show.subCount}` : '', show.dubCount ? `Dub ${show.dubCount}` : ''].filter(Boolean)
  return {
    tmdbId: 'kai:' + show.slug,
    type: 'tv',
    title: show.title,
    description: description || show.japaneseTitle || show.title,
    posterPath: show.posterURL,
    backdropPath: show.posterURL,
    rating: null,
    year: counts.length ? counts.join(' · ') : show.kind,
    popularity: 0,
    anime: true
  }
}

const catalogBase = () => useSettings.getState().animeServers[0]?.base
const catalogName = () => useSettings.getState().animeServers[0]?.name ?? 'AnimeKai'
const synopsisCache = new Map<string, string>()

export async function withSynopsis(item: MediaItem): Promise<MediaItem> {
  const slug = animeSlug(item), base = catalogBase()
  if (!slug || !base) return item
  if (synopsisCache.has(slug)) return { ...item, description: synopsisCache.get(slug)! }
  try {
    const d = await window.vela.anime.details(base, slug)
    if (d.description) { synopsisCache.set(slug, d.description); return { ...item, description: d.description } }
  } catch { /* keep card text */ }
  return item
}

interface AnimeCatalog { rows: MediaRow[]; loading: boolean; error: string | null; base: string | null; load: (force?: boolean) => Promise<void> }
export const useAnimeCatalog = create<AnimeCatalog>((set, get) => ({
  rows: [], loading: false, error: null, base: null,
  load: async force => {
    const base = catalogBase()
    if (!base) { set({ rows: [], error: 'Add an anime server in Settings.' }); return }
    if (!force && (get().loading || get().base === base)) return
    set({ loading: true, error: null })
    const lists = await Promise.all([
      '/most-viewed?page=1', '/filter?sort=latest-updated&page=1', '/filter?sort=score&page=1', '/filter?sort=latest-added&page=1'
    ].map(p => window.vela.anime.list(base, p).catch(() => [] as AnimeShow[])))
    const name = catalogName()
    const rows = [
      { title: 'Most viewed', subtitle: `Popular on ${name}`, items: lists[0].map(s => animeItem(s)) },
      { title: 'New episodes', subtitle: 'Latest updated', items: lists[1].map(s => animeItem(s)) },
      { title: 'Top rated', subtitle: 'Highest scores', items: lists[2].map(s => animeItem(s)) },
      { title: 'Newly added', subtitle: 'Just arrived', items: lists[3].map(s => animeItem(s)) }
    ].filter(r => r.items.length)
    set({ rows, loading: false, base, error: rows.length ? null : `Couldn’t reach ${name}. Check your connection or try another anime server in Settings.` })
  }
}))

export function AnimePage() {
  const { rows, loading, error, load } = useAnimeCatalog()
  const recents = useLibrary(s => s.recents)
  const addSearch = useLibrary(s => s.addSearch)
  const query = useSearch(s => s.query)
  const push = useNav(s => s.push)
  const refresh = useRefresh(s => s.token)
  const servers = useSettings(s => s.animeServers)

  useEffect(() => { load() }, [load, servers])
  useEffect(() => { if (refresh) load(true) }, [refresh, load])

  const { results, busy } = useDebouncedSearch(query, async q => {
    const base = catalogBase()
    return base ? (await window.vela.anime.search(base, q)).map(s => animeItem(s)) : []
  }, (q, n) => { if (n) addSearch(q, true) })

  const open = (item: MediaItem) => push({ name: 'anime-details', item })

  if (query.trim().length >= 2) {
    return (
      <div className="page">
        <div className="page-head"><span className="eyebrow">Search · {catalogName()}</span><h2 className="page-title">Results for “{query.trim()}”</h2></div>
        {busy && !results.length ? <Spinner label="Searching…" /> : results.length ? <Grid items={results} onOpen={open} /> : <StatusCard title="No matches" message="Try the English or Japanese title." />}
      </div>
    )
  }

  const cw = animeRecents(recents)
  return (
    <div className="page page-home">
      <AnimeHero items={rows[0]?.items ?? []} />
      {error && <StatusCard title="Anime unavailable" message={error} action={<button className="btn" onClick={() => load(true)}>Try again</button>} />}
      {cw.length > 0 && <Row row={{ title: 'Continue watching', subtitle: 'Saved on this device', items: cw }} onOpen={open} showProgress />}
      {loading && !rows.length ? <SkeletonRows /> : rows.map(r => <Row key={r.title} row={r} onOpen={open} />)}
    </div>
  )
}

/** Poster on the left over a blurred copy of itself, like the iOS banner. */
function AnimeHero({ items }: { items: MediaItem[] }) {
  const [index, setIndex] = useState(0)
  const [hero, setHero] = useState<MediaItem | null>(null)
  const playerOpen = usePlayer(s => s.open)
  const push = useNav(s => s.push)
  const toggle = useLibrary(s => s.toggleFavorite)
  const favorite = useIsFavorite(hero)

  useEffect(() => {
    const item = items[index % Math.max(1, items.length)]
    if (!item) { setHero(null); return }
    let live = true
    setHero(h => h ?? item)
    withSynopsis(item).then(i => live && setHero(i))
    return () => { live = false }
  }, [items, index])

  useEffect(() => {
    if (items.length < 2 || playerOpen) return
    const t = setInterval(() => setIndex(i => (i + 1) % items.length), 10_000)
    return () => clearInterval(t)
  }, [items, playerOpen])

  if (!hero) return <div className="hero hero-empty" />
  return (
    <section className="hero anime-hero" aria-label="Featured anime">
      <img key={hero.tmdbId} className="anime-hero-blur" src={hero.posterPath ?? ''} alt="" />
      <div className="hero-scrim" />
      <div className="anime-hero-body">
        <img key={hero.tmdbId + 'p'} className="anime-hero-poster" src={hero.posterPath ?? ''} alt="" />
        <div className="hero-content">
          <span className="eyebrow">{hero.year}</span>
          <h2 className="hero-title">{hero.title}</h2>
          <p className="hero-desc clamp-3">{hero.description}</p>
          <div className="hero-actions">
            <button className="btn btn-primary" onClick={() => push({ name: 'anime-details', item: hero })}><Icon name="play" size={14} fill />Play</button>
            <button className="btn btn-icon" aria-label={favorite ? 'Remove from favourites' : 'Add to favourites'} onClick={() => toast(toggle(hero) ? 'Added to favourites' : 'Removed from favourites')}>
              <Icon name="heart" size={15} fill={favorite} />
            </button>
          </div>
        </div>
      </div>
      {items.length > 1 && (
        <div className="hero-dots">
          {items.slice(0, 15).map((it, i) => <button key={it.tmdbId} aria-label={it.title} className={cx('dot', i === index % items.length && 'is-active')} onClick={() => setIndex(i)} />)}
        </div>
      )}
    </section>
  )
}
