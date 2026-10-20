import { useEffect, useRef, useState, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import type { MediaItem, MediaRow } from '@shared/types'
import { Icon } from './Icon'
import { imageUrl, isAnimeCatalog } from '@/lib/tmdb'
import { progressFor, progressFraction, useIsFavorite, useLibrary } from '@/stores/library'
import { useSettings } from '@/stores/settings'
import { toast, useToast } from '@/stores/ui'
import { cx } from '@/lib/format'

// ── Context menu ──────────────────────────────────────────────────────
export interface MenuAction { label: string; onSelect: () => void; danger?: boolean; separator?: boolean }
type MenuState = { x: number; y: number; actions: MenuAction[] } | null
let openMenu: (m: MenuState) => void = () => {}

export function showContextMenu(e: React.MouseEvent, actions: MenuAction[]) {
  e.preventDefault()
  openMenu({ x: e.clientX, y: e.clientY, actions })
}

export function ContextMenuHost() {
  const [menu, setMenu] = useState<MenuState>(null)
  const ref = useRef<HTMLDivElement>(null)
  openMenu = setMenu
  useEffect(() => {
    if (!menu) return
    const close = () => setMenu(null)
    const key = (e: KeyboardEvent) => { if (e.key === 'Escape') close() }
    window.addEventListener('mousedown', close)
    window.addEventListener('blur', close)
    window.addEventListener('keydown', key)
    ref.current?.querySelector<HTMLButtonElement>('button')?.focus()
    return () => { window.removeEventListener('mousedown', close); window.removeEventListener('blur', close); window.removeEventListener('keydown', key) }
  }, [menu])
  if (!menu) return null
  const x = Math.min(menu.x, window.innerWidth - 220), y = Math.min(menu.y, window.innerHeight - menu.actions.length * 30 - 16)
  return (
    <div ref={ref} className="menu context-menu glass-strong" role="menu" style={{ left: x, top: y }} onMouseDown={e => e.stopPropagation()}>
      {menu.actions.map((a, i) => (
        <div key={i}>
          {a.separator && <div className="menu-sep" />}
          <button role="menuitem" className={cx('menu-item', a.danger && 'is-danger')} onClick={() => { setMenu(null); a.onSelect() }}>{a.label}</button>
        </div>
      ))}
    </div>
  )
}

// ── Popover menu (Quality / Server / Captions etc.) ───────────────────
export function MenuButton({ label, icon, children, align = 'right', className }: { label: ReactNode; icon?: Parameters<typeof Icon>[0]['name']; children: (close: () => void) => ReactNode; align?: 'left' | 'right'; className?: string }) {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!open) return
    const down = (e: MouseEvent) => { if (!ref.current?.contains(e.target as Node)) setOpen(false) }
    const key = (e: KeyboardEvent) => { if (e.key === 'Escape') { e.stopPropagation(); setOpen(false) } }
    window.addEventListener('mousedown', down)
    window.addEventListener('keydown', key, true)
    return () => { window.removeEventListener('mousedown', down); window.removeEventListener('keydown', key, true) }
  }, [open])
  return (
    <div className={cx('menu-anchor', className)} ref={ref}>
      <button className={cx('pill-btn', open && 'is-open')} aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen(o => !o)}>
        {icon && <Icon name={icon} size={14} />}<span>{label}</span><Icon name="chevronDown" size={11} stroke={2.4} />
      </button>
      {open && <div className={cx('menu popover glass-strong', align === 'left' && 'is-left')} role="menu">{children(() => setOpen(false))}</div>}
    </div>
  )
}

export function MenuItem({ selected, onSelect, children, disabled }: { selected?: boolean; onSelect: () => void; children: ReactNode; disabled?: boolean }) {
  return (
    <button role="menuitemradio" aria-checked={!!selected} disabled={disabled} className="menu-item" onClick={onSelect}>
      <span className="menu-check">{selected && <Icon name="check" size={12} stroke={2.6} />}</span>{children}
    </button>
  )
}

// ── Poster card + row ─────────────────────────────────────────────────
export function PosterCard({ item, onOpen, onPlay, showProgress }: { item: MediaItem; onOpen: (i: MediaItem) => void; onPlay?: (i: MediaItem) => void; showProgress?: boolean }) {
  const favorite = useIsFavorite(item)
  const progress = useLibrary(s => (showProgress ? progressFraction(progressFor(s.watchProgress, item)) : 0))
  const toggleFavorite = useLibrary(s => s.toggleFavorite)
  const removeFromHistory = useLibrary(s => s.removeFromHistory)
  const compact = useSettings(s => s.cardSize === 'compact')
  const [loaded, setLoaded] = useState(false)
  const [preview, setPreview] = useState<DOMRect | null>(null)
  const hoverTimer = useRef<ReturnType<typeof setTimeout>>(undefined)
  useEffect(() => () => clearTimeout(hoverTimer.current), [])
  // Posters render at 128-168px; w342 covers that at 2x, w500 only for hi-DPI large cards.
  const src = imageUrl(item.posterPath, 'w342')
  const srcSet = item.posterPath && !item.posterPath.startsWith('http')
    ? `${imageUrl(item.posterPath, 'w185')} 185w, ${imageUrl(item.posterPath, 'w342')} 342w, ${imageUrl(item.posterPath, 'w500')} 500w`
    : undefined
  const meta = isAnimeCatalog(item) ? item.year : [item.type === 'movie' ? 'Movie' : 'TV', item.year].filter(Boolean).join(' · ')
  const resume = showProgress && item.resumeEpisode != null && item.type === 'tv' ? (isAnimeCatalog(item) ? `Episode ${item.resumeEpisode}` : `S${item.resumeSeason} · E${item.resumeEpisode}`) : null

  return (
    <>
    <button
      className={cx('poster', compact && 'is-compact')}
      onMouseEnter={e => {
        const el = e.currentTarget
        clearTimeout(hoverTimer.current)
        hoverTimer.current = setTimeout(() => setPreview(el.getBoundingClientRect()), 550)
      }}
      onMouseLeave={() => clearTimeout(hoverTimer.current)}
      onMouseDown={() => clearTimeout(hoverTimer.current)}
      onClick={() => onOpen(item)}
      onContextMenu={e => {
        // Read on demand instead of subscribing every card to the history list.
        const inHistory = useLibrary.getState().recents.some(r => r.tmdbId === item.tmdbId && r.type === item.type)
        showContextMenu(e, [
        ...(onPlay ? [{ label: 'Play', onSelect: () => onPlay(item) }] : []),
        { label: 'Open', onSelect: () => onOpen(item) },
        { label: favorite ? 'Remove from Favourites' : 'Add to Favourites', separator: true, onSelect: () => toast(toggleFavorite(item) ? 'Added to favourites' : 'Removed from favourites') },
        ...(inHistory ? [{ label: 'Remove from Continue Watching', danger: true, onSelect: () => removeFromHistory(item) }] : []),
        ...(!isAnimeCatalog(item) ? [{ label: 'View on TMDB', separator: true, onSelect: () => window.vela.openExternal(`https://www.themoviedb.org/${item.type}/${item.tmdbId}`) }] : [])
        ])
      }}
      aria-label={`${item.title}${meta ? ', ' + meta : ''}`}
    >
      <div className="poster-art">
        {src ? <img src={src} srcSet={srcSet} sizes={compact ? '128px' : '168px'} alt="" loading="lazy" decoding="async" draggable={false} className={cx(loaded && 'is-loaded')} onLoad={() => setLoaded(true)} /> : <div className="poster-fallback">{item.title}</div>}
        {favorite && <span className="poster-badge" aria-label="Favourite"><Icon name="heart" size={12} fill /></span>}
        {item.rating ? <span className="poster-rating"><Icon name="star" size={10} fill />{item.rating.toFixed(1)}</span> : null}
        {progress > 0 && <div className="progress"><div style={{ width: `${progress * 100}%` }} /></div>}
      </div>
      <div className="poster-title clamp-1">{item.title}</div>
      <div className="poster-meta clamp-1">{resume ?? meta}</div>
    </button>
    {preview && createPortal(
      <PosterPreview item={item} rect={preview} meta={resume ?? meta} progress={progress} favorite={favorite}
        onClose={() => setPreview(null)}
        onOpen={() => { setPreview(null); onOpen(item) }}
        onPlay={() => { setPreview(null); (onPlay ?? onOpen)(item) }}
        onFavorite={() => toast(toggleFavorite(item) ? 'Added to favourites' : 'Removed from favourites')} />,
      document.body
    )}
    </>
  )
}

/** Enlarged card shown after hovering a poster for 0.55s. */
function PosterPreview({ item, rect, meta, progress, favorite, onClose, onOpen, onPlay, onFavorite }: {
  item: MediaItem; rect: DOMRect; meta: string; progress: number; favorite: boolean
  onClose: () => void; onOpen: () => void; onPlay: () => void; onFavorite: () => void
}) {
  useEffect(() => {
    const close = () => onClose()
    window.addEventListener('scroll', close, true)
    window.addEventListener('blur', close)
    window.addEventListener('resize', close)
    return () => { window.removeEventListener('scroll', close, true); window.removeEventListener('blur', close); window.removeEventListener('resize', close) }
  }, [onClose])
  const width = 340
  const left = Math.max(12, Math.min(window.innerWidth - width - 12, rect.left + rect.width / 2 - width / 2))
  const top = Math.max(12, Math.min(window.innerHeight - 380, rect.top + rect.height / 2 - 190))
  const art = imageUrl(item.backdropPath || item.posterPath, 'w780')
  return (
    <div className="poster-preview glass-strong" style={{ left, top, width }} onMouseLeave={onClose} role="dialog" aria-label={item.title}>
      <button className="preview-art" onClick={onOpen} aria-label={`Open ${item.title}`}>
        {art && <img src={art} alt="" className={cx(isAnimeCatalog(item) && 'is-anime')} />}
        {progress > 0 && <div className="progress"><div style={{ width: `${progress * 100}%` }} /></div>}
      </button>
      <div className="preview-body">
        <div className="preview-title clamp-2">{item.title}</div>
        <div className="preview-meta">
          {item.rating ? <span><Icon name="star" size={10} fill /> {item.rating.toFixed(1)}</span> : null}
          <span>{meta}</span>
        </div>
        <p className="preview-desc clamp-3">{item.description}</p>
        <div className="hero-actions">
          <button className="btn btn-primary small" onClick={onPlay}><Icon name="play" size={12} fill />Play</button>
          <button className="btn small" onClick={onOpen}><Icon name="info" size={12} />Details</button>
          <button className="btn btn-icon small" aria-label={favorite ? 'Remove from favourites' : 'Add to favourites'} onClick={onFavorite}><Icon name="heart" size={13} fill={favorite} /></button>
        </div>
      </div>
    </div>
  )
}

export function Row({ row, onOpen, onPlay, showProgress }: { row: MediaRow; onOpen: (i: MediaItem) => void; onPlay?: (i: MediaItem) => void; showProgress?: boolean }) {
  const scroller = useRef<HTMLDivElement>(null)
  const scroll = (dir: number) => scroller.current?.scrollBy({ left: dir * scroller.current.clientWidth * 0.85, behavior: 'smooth' })
  return (
    <section className="row" aria-label={row.title}>
      <div className="row-head">
        <div>
          <h2>{row.title}</h2>
          <p className="muted">{row.subtitle}</p>
        </div>
        <div className="row-nav">
          <button className="tb-btn" aria-label={`Scroll ${row.title} left`} onClick={() => scroll(-1)}><Icon name="chevronLeft" /></button>
          <button className="tb-btn" aria-label={`Scroll ${row.title} right`} onClick={() => scroll(1)}><Icon name="chevronRight" /></button>
        </div>
      </div>
      <div className="row-scroller no-scrollbar" ref={scroller}>
        {row.items.map(i => <PosterCard key={i.type + i.tmdbId} item={i} onOpen={onOpen} onPlay={onPlay} showProgress={showProgress} />)}
      </div>
    </section>
  )
}

export function Grid({ items, onOpen, onPlay, showProgress }: { items: MediaItem[]; onOpen: (i: MediaItem) => void; onPlay?: (i: MediaItem) => void; showProgress?: boolean }) {
  return <div className="grid">{items.map(i => <PosterCard key={i.type + i.tmdbId} item={i} onOpen={onOpen} onPlay={onPlay} showProgress={showProgress} />)}</div>
}

export function Toast() {
  const message = useToast(s => s.message)
  return <div className={cx('toast glass-strong', message && 'is-visible')} role="status" aria-live="polite">{message}</div>
}

export function StatusCard({ title, message, action }: { title: string; message?: string; action?: ReactNode }) {
  return (
    <div className="status-card glass">
      <h3>{title}</h3>
      {message && <p className="muted">{message}</p>}
      {action}
    </div>
  )
}

export function Spinner({ label }: { label?: string }) {
  return <div className="spinner-wrap" role="status"><div className="spinner" />{label && <span className="muted">{label}</span>}</div>
}

export function SkeletonRows() {
  return (
    <>{[0, 1].map(r => (
      <section className="row" key={r} aria-hidden="true">
        <div className="row-head"><div><div className="skeleton" style={{ width: 200, height: 20 }} /><div className="skeleton" style={{ width: 140, height: 12, marginTop: 8 }} /></div></div>
        <div className="row-scroller no-scrollbar">{Array.from({ length: 8 }, (_, i) => <div key={i} className="poster"><div className="poster-art skeleton" /></div>)}</div>
      </section>
    ))}</>
  )
}
