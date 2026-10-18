import { useEffect, useState } from 'react'
import type { MediaItem } from '@shared/types'
import { Icon } from '@/components/Icon'
import { imageUrl } from '@/lib/tmdb'
import { useIsFavorite, useLibrary } from '@/stores/library'
import { usePlayer } from '@/stores/player'
import { toast, useNav } from '@/stores/ui'
import { quickPlay } from '../details/actions'
import { cx } from '@/lib/format'

/** Large backdrop banner that cycles through the home items every 10s. */
export function Hero({ items }: { items: MediaItem[] }) {
  const [index, setIndex] = useState(0)
  const playerOpen = usePlayer(s => s.open)
  const push = useNav(s => s.push)
  const item = items[index % Math.max(items.length, 1)]
  const favorite = useIsFavorite(item)
  const toggle = useLibrary(s => s.toggleFavorite)

  useEffect(() => {
    if (items.length < 2 || playerOpen) return
    const t = setInterval(() => {
      setIndex(i => {
        const next = (i + 1) % items.length
        const pre = new Image(); pre.src = imageUrl(items[(next + 1) % items.length].backdropPath, 'w1280')
        return next
      })
    }, 10_000)
    return () => clearInterval(t)
  }, [items, playerOpen])

  if (!item) return <div className="hero hero-empty" />

  return (
    <section className="hero" aria-label="Featured">
      {items.map((it, i) => (
        <img key={it.type + it.tmdbId} className={cx('hero-bg', i === index % items.length && 'is-active')} src={Math.abs(i - index) <= 1 ? imageUrl(it.backdropPath, 'w1280') : undefined} alt="" />
      ))}
      <div className="hero-scrim" />
      <div className="hero-content">
        <span className="eyebrow">{item.type === 'movie' ? 'Movie' : 'Series'}{item.year ? ` · ${item.year}` : ''}{item.rating ? ` · ★ ${item.rating.toFixed(1)}` : ''}</span>
        <h2 className="hero-title">{item.title}</h2>
        <p className="hero-desc clamp-3">{item.description}</p>
        <div className="hero-actions">
          <button className="btn btn-primary" onClick={() => quickPlay(item)}><Icon name="play" size={14} fill />Play</button>
          <button className="btn" onClick={() => push({ name: 'details', item })}><Icon name="info" size={14} />More info</button>
          <button className="btn btn-icon" aria-label={favorite ? 'Remove from favourites' : 'Add to favourites'} onClick={() => toast(toggle(item) ? 'Added to favourites' : 'Removed from favourites')}>
            <Icon name="heart" size={15} fill={favorite} />
          </button>
        </div>
      </div>
      {items.length > 1 && (
        <div className="hero-dots" role="tablist" aria-label="Featured titles">
          {items.map((it, i) => <button key={it.tmdbId + it.type} role="tab" aria-selected={i === index % items.length} aria-label={it.title} className={cx('dot', i === index % items.length && 'is-active')} onClick={() => setIndex(i)} />)}
        </div>
      )}
    </section>
  )
}
