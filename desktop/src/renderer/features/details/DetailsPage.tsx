import { useEffect, useMemo, useState } from 'react'
import type { MediaItem } from '@shared/types'
import { Icon } from '@/components/Icon'
import { MenuButton, MenuItem, Spinner } from '@/components/Media'
import { imageUrl, tmdb, type CastMember, type TvDetails, type TvEpisode } from '@/lib/tmdb'
import { progressFraction, useIsFavorite, useLibrary } from '@/stores/library'
import { usePlayer } from '@/stores/player'
import { toast } from '@/stores/ui'
import { seasonsOf } from './actions'
import { cx } from '@/lib/format'
import { IntroTimes } from '@/components/IntroTimes'

export function DetailsPage({ item }: { item: MediaItem }) {
  const [tv, setTv] = useState<TvDetails | null>(null)
  const [season, setSeason] = useState<number | null>(item.resumeSeason ?? null)
  const [episodes, setEpisodes] = useState<TvEpisode[] | null>(null)
  const [cast, setCast] = useState<CastMember[]>([])
  const [error, setError] = useState<string | null>(null)
  const [epQuery, setEpQuery] = useState('')
  const favorite = useIsFavorite(item)
  const toggle = useLibrary(s => s.toggleFavorite)
  const progress = useLibrary(s => s.watchProgress)
  const recent = useLibrary(s => s.recents.find(r => r.tmdbId === item.tmdbId && r.type === item.type))
  const playTmdb = usePlayer(s => s.playTmdb)

  useEffect(() => {
    let live = true
    setError(null)
    tmdb<{ cast: CastMember[] }>(`/${item.type}/${item.tmdbId}/credits`).then(r => live && setCast(r.cast.slice(0, 15))).catch(() => {})
    if (item.type === 'tv') {
      tmdb<TvDetails>(`/tv/${item.tmdbId}`).then(d => {
        if (!live) return
        setTv(d)
        const first = seasonsOf(d)[0]?.seasonNumber ?? 1
        setSeason(s => s ?? recent?.resumeSeason ?? first)
      }).catch(e => live && setError((e as Error).message))
    }
    return () => { live = false }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [item.tmdbId, item.type])

  useEffect(() => {
    if (item.type !== 'tv' || season == null) return
    let live = true
    setEpisodes(null)
    tmdb<{ episodes: TvEpisode[] }>(`/tv/${item.tmdbId}/season/${season}`)
      .then(r => live && setEpisodes(r.episodes ?? []))
      .catch(() => live && setEpisodes([]))
    return () => { live = false }
  }, [item.tmdbId, item.type, season])

  const seasons = useMemo(() => (tv ? seasonsOf(tv) : []), [tv])
  const filtered = useMemo(() => {
    const q = epQuery.trim().toLowerCase()
    return !q || !episodes ? episodes ?? [] : episodes.filter(e => String(e.episode_number) === q || e.name.toLowerCase().includes(q))
  }, [episodes, epQuery])

  const playEpisode = (ep: TvEpisode) => playTmdb(item, { seasons, season: ep.season_number, episode: ep.episode_number, episodeTitle: ep.name })
  const play = () => {
    if (item.type === 'movie') { playTmdb(item); return }
    if (!seasons.length) return
    const s = recent?.resumeSeason ?? seasons[0].seasonNumber
    const e = recent?.resumeEpisode ?? 1
    playTmdb(item, { seasons, season: s, episode: e, episodeTitle: recent?.resumeTitle })
  }
  const resumeLabel = item.type === 'tv' && recent?.resumeEpisode ? `Resume S${recent.resumeSeason} · E${recent.resumeEpisode}` : progress.some(p => p.id === `movie:${item.tmdbId}` && !p.completed) ? 'Resume' : 'Play'
  const genres = tv?.genres?.map(g => g.name).slice(0, 3).join(', ')

  return (
    <div className={cx('page details', item.type === 'tv' && 'has-inspector')}>
      <div className="details-main">
        <section className="details-hero">
          {item.backdropPath && <img className="details-backdrop" src={imageUrl(item.backdropPath, 'w1280')} alt="" />}
          <div className="hero-scrim" />
          <div className="details-hero-body">
            {item.posterPath && <img className="details-poster" src={imageUrl(item.posterPath, 'w500')} alt="" />}
            <div>
              <span className="eyebrow">{[item.type === 'movie' ? 'Movie' : 'Series', item.year, genres].filter(Boolean).join(' · ')}</span>
              <h2 className="details-title">{item.title}</h2>
              {item.rating ? <div className="details-rating"><Icon name="star" size={12} fill /> {item.rating.toFixed(1)} on TMDB</div> : null}
              <p className="details-desc">{item.description}</p>
              <div className="hero-actions">
                <button className="btn btn-primary" onClick={play} disabled={item.type === 'tv' && !seasons.length}><Icon name="play" size={14} fill />{resumeLabel}</button>
                <button className="btn" onClick={() => toast(toggle(item) ? 'Added to favourites' : 'Removed from favourites')}>
                  <Icon name="heart" size={14} fill={favorite} />{favorite ? 'In Favourites' : 'Favourite'}
                </button>
                <button className="btn btn-icon" aria-label="View on TMDB" title="View on TMDB" onClick={() => window.vela.openExternal(`https://www.themoviedb.org/${item.type}/${item.tmdbId}`)}><Icon name="info" size={15} /></button>
              </div>
              {item.type === 'tv' && <IntroTimes item={item} />}
            </div>
          </div>
        </section>

        {error && <p className="muted pad">{error}</p>}

        {cast.length > 0 && (
          <section className="row">
            <div className="row-head"><div><h2>Cast</h2></div></div>
            <div className="row-scroller no-scrollbar cast-row">
              {cast.map(c => (
                <button key={c.id} className="cast" onClick={() => window.vela.openExternal(`https://www.themoviedb.org/person/${c.id}`)} aria-label={`${c.name}${c.character ? ' as ' + c.character : ''}`}>
                  <div className="cast-photo">{c.profile_path ? <img src={imageUrl(c.profile_path, 'w300')} alt="" loading="lazy" /> : <span>{c.name[0]}</span>}</div>
                  <div className="cast-name clamp-1">{c.name}</div>
                  <div className="cast-role clamp-1">{c.character}</div>
                </button>
              ))}
            </div>
          </section>
        )}
      </div>

      {item.type === 'tv' && (
        <aside className="inspector glass" aria-label="Episodes">
          <div className="inspector-head">
            {seasons.length > 0 && season != null && (
              <MenuButton label={tv?.seasons.find(s => s.season_number === season)?.name ?? `Season ${season}`} align="left">
                {close => seasons.map(s => (
                  <MenuItem key={s.seasonNumber} selected={s.seasonNumber === season} onSelect={() => { setSeason(s.seasonNumber); close() }}>
                    {tv?.seasons.find(x => x.season_number === s.seasonNumber)?.name ?? `Season ${s.seasonNumber}`} <span className="muted">· {s.episodeCount}</span>
                  </MenuItem>
                ))}
              </MenuButton>
            )}
            <div className="mini-search"><Icon name="search" size={12} /><input placeholder="Episode" aria-label="Filter episodes" value={epQuery} onChange={e => setEpQuery(e.target.value)} /></div>
          </div>
          <div className="episode-list">
            {episodes === null ? <Spinner /> : filtered.length === 0 ? <p className="muted pad">No episodes.</p> : filtered.map(ep => {
              const p = progressFraction(progress.find(x => x.id === `tv:${item.tmdbId}:${ep.season_number}:${ep.episode_number}`))
              const current = recent?.resumeSeason === ep.season_number && recent?.resumeEpisode === ep.episode_number
              return (
                <button key={ep.episode_number} className={cx('episode', current && 'is-current')} onClick={() => playEpisode(ep)}>
                  <div className="episode-still">
                    {ep.still_path ? <img src={imageUrl(ep.still_path, 'w300')} alt="" loading="lazy" /> : null}
                    <span className="episode-play"><Icon name="play" size={14} fill /></span>
                    {p > 0 && <div className="progress"><div style={{ width: `${p * 100}%` }} /></div>}
                  </div>
                  <div className="episode-text">
                    <div className="episode-num">Episode {ep.episode_number}{ep.runtime ? ` · ${ep.runtime}m` : ''}</div>
                    <div className="episode-name clamp-1">{ep.name}</div>
                    <div className="episode-desc clamp-2">{ep.overview}</div>
                  </div>
                </button>
              )
            })}
          </div>
        </aside>
      )}
    </div>
  )
}
