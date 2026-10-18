import { useEffect, useMemo, useState } from 'react'
import type { AnimeDetails, AnimeEpisode, MediaItem } from '@shared/types'
import { Icon } from '@/components/Icon'
import { Spinner, StatusCard } from '@/components/Media'
import { animeSlug } from '@/lib/tmdb'
import { progressFraction, useIsFavorite, useLibrary } from '@/stores/library'
import { usePlayer } from '@/stores/player'
import { useSettings } from '@/stores/settings'
import { toast } from '@/stores/ui'
import { cx } from '@/lib/format'

export function AnimeDetailsPage({ item }: { item: MediaItem }) {
  const [details, setDetails] = useState<AnimeDetails | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [query, setQuery] = useState('')
  const [audio, setAudio] = useState<'all' | 'sub' | 'dub'>('all')
  const server = useSettings(s => s.animeServers[0])
  const progress = useLibrary(s => s.watchProgress)
  const recent = useLibrary(s => s.recents.find(r => r.tmdbId === item.tmdbId))
  const favorite = useIsFavorite(item)
  const toggle = useLibrary(s => s.toggleFavorite)
  const playAnime = usePlayer(s => s.playAnime)
  const playing = usePlayer(s => (s.item?.tmdbId === item.tmdbId ? s.anime?.episode.number : null))

  const load = () => {
    const slug = animeSlug(item)
    if (!slug || !server) { setError('No anime server configured.'); return }
    setError(null); setDetails(null)
    window.vela.anime.details(server.base, slug)
      .then(setDetails)
      .catch(e => setError((e as Error).message.replace(/^Error invoking remote method '[^']+': (Error: )?/, '')))
  }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(load, [item.tmdbId, server?.base])

  const full: MediaItem = useMemo(() => details ? {
    ...item,
    description: details.description || item.description,
    posterPath: item.posterPath || details.show.posterURL,
    backdropPath: item.backdropPath || details.show.posterURL
  } : item, [details, item])

  const episodes = useMemo(() => {
    const q = query.trim().toLowerCase()
    return (details?.episodes ?? []).filter(e =>
      (audio === 'all' || (audio === 'sub' ? e.hasSub : e.hasDub)) &&
      (!q || e.number === q || e.title.toLowerCase().includes(q)))
  }, [details, query, audio])

  const play = (ep: AnimeEpisode) => details && playAnime(full, details, ep, 0)
  const resumeEp = details?.episodes.find(e => Math.floor(Number(e.number)) === recent?.resumeEpisode) ?? details?.episodes[0]

  return (
    <div className="page details has-inspector">
      <div className="details-main">
        <section className="details-hero anime">
          {full.posterPath && <img className="details-backdrop blurred" src={full.posterPath} alt="" />}
          <div className="hero-scrim" />
          <div className="details-hero-body">
            {full.posterPath && <img className="details-poster" src={full.posterPath} alt="" />}
            <div>
              <span className="eyebrow">{[details?.show.kind, full.year].filter(Boolean).join(' · ')}</span>
              <h2 className="details-title">{full.title}</h2>
              {details?.show.japaneseTitle && <div className="details-rating">{details.show.japaneseTitle}</div>}
              <p className="details-desc">{full.description}</p>
              <div className="hero-actions">
                <button className="btn btn-primary" disabled={!resumeEp} onClick={() => resumeEp && play(resumeEp)}>
                  <Icon name="play" size={14} fill />{recent?.resumeEpisode ? `Resume Episode ${recent.resumeEpisode}` : 'Play'}
                </button>
                <button className="btn" onClick={() => toast(toggle(full) ? 'Added to favourites' : 'Removed from favourites')}>
                  <Icon name="heart" size={14} fill={favorite} />{favorite ? 'In Favourites' : 'Favourite'}
                </button>
              </div>
            </div>
          </div>
        </section>
        {error && <StatusCard title="Couldn’t load this title" message={error} action={<button className="btn" onClick={load}>Try again</button>} />}
      </div>

      <aside className="inspector glass" aria-label="Episodes">
        <div className="inspector-head">
          <div className="segmented small" role="radiogroup" aria-label="Audio">
            {(['all', 'sub', 'dub'] as const).map(a => (
              <button key={a} role="radio" aria-checked={audio === a} className={cx('seg', audio === a && 'is-active')} onClick={() => setAudio(a)}>{a === 'all' ? 'All' : a === 'sub' ? 'Sub' : 'Dub'}</button>
            ))}
          </div>
          <div className="mini-search"><Icon name="search" size={12} /><input placeholder="Episode" aria-label="Filter episodes" value={query} onChange={e => setQuery(e.target.value)} /></div>
        </div>
        <div className="episode-list compact">
          {!details && !error ? <Spinner label="Loading episodes…" /> : episodes.length === 0 ? <p className="muted pad">No episodes.</p> : episodes.map(ep => {
            const n = Math.floor(Number(ep.number))
            const p = progressFraction(progress.find(x => x.id === `tv:${item.tmdbId}:1:${n}`))
            return (
              <button key={ep.number} className={cx('episode anime-ep', (playing === ep.number || (!playing && recent?.resumeEpisode === n)) && 'is-current')} onClick={() => play(ep)}>
                <span className="ep-number">{ep.number}</span>
                <div className="episode-text">
                  <div className="episode-name clamp-1">{ep.title}</div>
                  <div className="ep-tags">
                    {ep.hasSub && <span className="tag">SUB</span>}
                    {ep.hasDub && <span className="tag">DUB</span>}
                  </div>
                  {p > 0 && <div className="progress inline"><div style={{ width: `${p * 100}%` }} /></div>}
                </div>
              </button>
            )
          })}
        </div>
      </aside>
    </div>
  )
}
