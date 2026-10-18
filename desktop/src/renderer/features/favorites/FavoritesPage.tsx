import type { MediaItem } from '@shared/types'
import { Grid, StatusCard } from '@/components/Media'
import { isAnimeCatalog } from '@/lib/tmdb'
import { useLibrary } from '@/stores/library'
import { useSettings } from '@/stores/settings'
import { useNav, useSearch } from '@/stores/ui'
import { quickPlay } from '../details/actions'

export function FavoritesPage() {
  const favorites = useLibrary(s => s.favorites)
  const animeEnabled = useSettings(s => s.animeEnabled)
  const query = useSearch(s => s.query.trim().toLowerCase())
  const push = useNav(s => s.push)
  const open = (i: MediaItem) => push(isAnimeCatalog(i) ? { name: 'anime-details', item: i } : { name: 'details', item: i })
  const visible = favorites.filter(f => (animeEnabled || !isAnimeCatalog(f)) && (!query || f.title.toLowerCase().includes(query)))
  const sections = [
    { title: 'Movies', items: visible.filter(i => i.type === 'movie') },
    { title: 'TV Shows', items: visible.filter(i => i.type === 'tv' && !isAnimeCatalog(i)) },
    { title: 'Anime', items: visible.filter(isAnimeCatalog) }
  ].filter(s => s.items.length)

  return (
    <div className="page">
      <div className="page-head"><span className="eyebrow">Library</span><h2 className="page-title">Favourites</h2></div>
      {sections.length === 0
        ? <StatusCard title={query ? 'No matches' : 'Nothing saved yet'} message={query ? undefined : 'Right-click any poster or use the heart button to save it here.'} />
        : sections.map(s => (
          <section key={s.title} className="fav-section">
            <h3 className="section-title">{s.title} <span className="muted">{s.items.length}</span></h3>
            <Grid items={s.items} onOpen={open} onPlay={i => (isAnimeCatalog(i) ? open(i) : quickPlay(i))} />
          </section>
        ))}
    </div>
  )
}
