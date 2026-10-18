// Window chrome: macOS-style traffic lights, unified toolbar and the
// floating glass sidebar.
import { useEffect, useRef, useState } from 'react'
import { Icon, type IconName } from './Icon'
import { useNav, useSearch, useRefresh, type Route } from '@/stores/ui'
import { useSettings, type ContentFilter } from '@/stores/settings'
import { useLibrary } from '@/stores/library'
import { cx } from '@/lib/format'
import { useLink } from '@/stores/link'

/** Greys the traffic lights only when the window itself is inactive, like macOS. */
export function useWindowFocusClass() {
  useEffect(() => {
    const update = () => document.body.classList.toggle('window-inactive', !document.hasFocus())
    update()
    window.addEventListener('focus', update)
    window.addEventListener('blur', update)
    return () => { window.removeEventListener('focus', update); window.removeEventListener('blur', update) }
  }, [])
}

export function TrafficLights() {
  return (
    <div className="traffic" role="group" aria-label="Window controls">
      <button className="tl tl-close" aria-label="Close" onClick={() => window.vela.window.close()}><svg viewBox="0 0 12 12"><path d="M3.5 3.5l5 5M8.5 3.5l-5 5" /></svg></button>
      <button className="tl tl-min" aria-label="Minimise" onClick={() => window.vela.window.minimize()}><svg viewBox="0 0 12 12"><path d="M3 6h6" /></svg></button>
      <button className="tl tl-max" aria-label="Zoom" onClick={() => window.vela.window.toggleMaximize()}><svg viewBox="0 0 12 12"><path d="M3.5 8.5V4.6l3.9 3.9zM8.5 3.5v3.9L4.6 3.5z" fill="currentColor" stroke="none" /></svg></button>
    </div>
  )
}

const sectionTitle = (r: Route) =>
  r.name === 'home' ? 'Home' : r.name === 'anime' ? 'Anime' : r.name === 'favorites' ? 'Favourites' : r.item.title

export function Toolbar() {
  const { route, back, forward, index, stack } = useNav()
  const { query, setQuery, focusToken } = useSearch()
  const filter = useSettings(s => s.contentFilter)
  const setSettings = useSettings(s => s.set)
  const history = useLibrary(s => (route.name === 'anime' ? s.animeSearchHistory : s.searchHistory))
  const bump = useRefresh(s => s.bump)
  const inputRef = useRef<HTMLInputElement>(null)
  const [focused, setFocused] = useState(false)
  const searchable = route.name === 'home' || route.name === 'anime' || route.name === 'favorites'

  useEffect(() => { if (focusToken) { inputRef.current?.focus(); inputRef.current?.select() } }, [focusToken])

  return (
    <header className="toolbar" onDoubleClick={e => { if (e.target === e.currentTarget) window.vela.window.toggleMaximize() }}>
      <div className="toolbar-nav">
        <button className="tb-btn" aria-label="Back" disabled={index === 0} onClick={back}><Icon name="chevronLeft" /></button>
        <button className="tb-btn" aria-label="Forward" disabled={index >= stack.length - 1} onClick={forward}><Icon name="chevronRight" /></button>
      </div>
      <h1 className="toolbar-title clamp-1">{sectionTitle(route)}</h1>

      <div className="toolbar-spacer" />
      {route.name === 'home' && !query && (
        <Segmented<ContentFilter>
          value={filter}
          onChange={v => setSettings({ contentFilter: v })}
          options={[{ value: 'all', label: 'All' }, { value: 'movie', label: 'Movies' }, { value: 'tv', label: 'TV Shows' }]}
        />
      )}
      {searchable && (
        <div className={cx('search-field', focused && 'is-focused')}>
          <Icon name="search" size={14} />
          <input
            ref={inputRef}
            value={query}
            placeholder={route.name === 'anime' ? 'Search anime' : 'Search movies and TV'}
            aria-label="Search"
            onChange={e => setQuery(e.target.value)}
            onFocus={() => setFocused(true)}
            onBlur={() => setTimeout(() => setFocused(false), 150)}
            onKeyDown={e => { if (e.key === 'Escape') { setQuery(''); inputRef.current?.blur() } }}
          />
          {query && <button className="search-clear" aria-label="Clear search" onClick={() => setQuery('')}><Icon name="close" size={11} stroke={2.4} /></button>}
          {focused && !query && history.length > 0 && (
            <div className="menu search-history glass-strong" role="listbox" aria-label="Recent searches">
              <div className="menu-label">Recent searches</div>
              {history.map(h => <button key={h} className="menu-item" role="option" aria-selected={false} onMouseDown={() => setQuery(h)}><Icon name="clock" size={13} />{h}</button>)}
            </div>
          )}
        </div>
      )}
      <ConnectButton />
      <button className="tb-btn" aria-label="Refresh" title="Refresh (Ctrl+R)" onClick={bump}><Icon name="refresh" /></button>
      <button className="tb-btn" aria-label="Menu" title="Menu" onClick={e => { const r = e.currentTarget.getBoundingClientRect(); window.vela.window.popupMenu(r.left, r.bottom + 6) }}><Icon name="ellipsis" stroke={3} /></button>
    </header>
  )
}

function ConnectButton() {
  const status = useLink(s => s.status)
  const live = (status?.devices ?? []).filter(d => d.connected)
  const label = live.length ? `Connected to ${live.map(d => d.name).join(', ')}` : 'Connect iPhone'
  return (
    <button className={cx('tb-btn', live.length > 0 && 'is-linked')} aria-label={label} title={label} onClick={() => useLink.getState().openConnect()}>
      <Icon name="phone" />
    </button>
  )
}

export function Segmented<T extends string>({ value, onChange, options }: { value: T; onChange: (v: T) => void; options: { value: T; label: string }[] }) {
  return (
    <div className="segmented" role="radiogroup">
      {options.map(o => (
        <button key={o.value} role="radio" aria-checked={value === o.value} className={cx('seg', value === o.value && 'is-active')} onClick={() => onChange(o.value)}>{o.label}</button>
      ))}
    </div>
  )
}

export function Sidebar() {
  const route = useNav(s => s.route)
  const stack = useNav(s => s.stack)
  const root = useNav(s => s.root)
  const collapsed = useSettings(s => s.sidebarCollapsed)
  const animeEnabled = useSettings(s => s.animeEnabled)
  const setQuery = useSearch(s => s.setQuery)
  const section = stack[0]?.name ?? route.name

  const items: { route: Route; label: string; icon: IconName }[] = [
    { route: { name: 'home' }, label: 'Home', icon: 'home' },
    ...(animeEnabled ? [{ route: { name: 'anime' } as Route, label: 'Anime', icon: 'sparkles' as IconName }] : []),
    { route: { name: 'favorites' }, label: 'Favourites', icon: 'heart' }
  ]

  return (
    <nav className={cx('sidebar glass', collapsed && 'is-collapsed')} aria-label="Sections">
      <TrafficLights />
      <div className="sidebar-brand">{!collapsed && <span>Vela</span>}</div>
      <div className="sidebar-group">
        {!collapsed && <div className="sidebar-label">Library</div>}
        {items.map(i => (
          <button key={i.label} className={cx('sidebar-item', section === i.route.name && 'is-active')} aria-current={section === i.route.name ? 'page' : undefined}
            title={collapsed ? i.label : undefined}
            onClick={() => { if (section !== i.route.name) setQuery(''); root(i.route) }}>
            <Icon name={i.icon} size={16} fill={section === i.route.name} />
            {!collapsed && <span>{i.label}</span>}
          </button>
        ))}
      </div>
      <div className="sidebar-footer">
        <button className="sidebar-item" title="Settings (Ctrl+,)" onClick={() => window.vela.window.openSettings()}>
          <Icon name="gear" size={16} />{!collapsed && <span>Settings</span>}
        </button>
        <button className="sidebar-item" aria-label="Toggle sidebar" title="Toggle sidebar (Ctrl+\)" onClick={() => useSettings.getState().set({ sidebarCollapsed: !collapsed })}>
          <Icon name="sidebar" size={16} />{!collapsed && <span>Collapse</span>}
        </button>
      </div>
    </nav>
  )
}
