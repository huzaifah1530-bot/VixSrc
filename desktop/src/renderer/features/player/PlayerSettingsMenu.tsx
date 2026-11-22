// The player's Settings button: a small popover with a list of options, each
// opening its own page (Quality, Server, Captions, …), like the system
// players. Pages slide in from the side and Back returns to the list.
import { useEffect, useRef, useState, type ReactNode } from 'react'
import { Icon, type IconName } from '@/components/Icon'
import { cx } from '@/lib/format'

export interface MenuChoice { key: string; label: ReactNode; selected: boolean; disabled?: boolean; onSelect: () => void }
export interface MenuSection { title?: string; choices: MenuChoice[]; note?: string | null }
export interface SettingsPage {
  id: string
  icon: IconName
  label: string
  /** Current value shown on the right of the row. */
  value?: string
  sections?: MenuSection[]
  /** Rows without pages act immediately (e.g. a toggle or an external link). */
  onSelect?: () => void
  external?: boolean
  toggle?: boolean
}

export function PlayerSettingsMenu({ pages, onOpenChange }: { pages: SettingsPage[]; onOpenChange?: (open: boolean) => void }) {
  const [open, setOpen] = useState(false)
  const [page, setPage] = useState<string | null>(null)
  const ref = useRef<HTMLDivElement>(null)
  const setOpenState = (next: boolean) => {
    setOpen(next)
    if (!next) setPage(null)
    onOpenChange?.(next)
  }
  useEffect(() => {
    if (!open) return
    const down = (e: MouseEvent) => { if (!ref.current?.contains(e.target as Node)) setOpenState(false) }
    const key = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
      e.stopPropagation()
      if (page) setPage(null); else setOpenState(false)
    }
    window.addEventListener('mousedown', down)
    window.addEventListener('keydown', key, true)
    return () => { window.removeEventListener('mousedown', down); window.removeEventListener('keydown', key, true) }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, page])

  const current = pages.find(p => p.id === page)
  return (
    <div className="menu-anchor" ref={ref}>
      <button className={cx('round-btn', open && 'is-open')} aria-label="Settings" title="Settings" aria-haspopup="menu" aria-expanded={open}
        onClick={() => setOpenState(!open)}>
        <Icon name="gear" size={17} />
      </button>
      {open && (
        <div className="menu popover glass-strong player-settings" role="menu">
          {current?.sections ? (
            <div key={current.id} className="player-settings-page is-sub">
              <button className="player-settings-back" onClick={() => setPage(null)}>
                <Icon name="chevronLeft" size={14} stroke={2.4} /><span>{current.label}</span>
              </button>
              {current.sections.map((section, i) => (
                <div key={i}>
                  {section.title && <div className="menu-label">{section.title}</div>}
                  {section.choices.map(c => (
                    <button key={c.key} role="menuitemradio" aria-checked={c.selected} disabled={c.disabled} className="menu-item"
                      onClick={() => { c.onSelect(); setOpenState(false) }}>
                      <span className="menu-check">{c.selected && <Icon name="check" size={12} stroke={2.6} />}</span>{c.label}
                    </button>
                  ))}
                  {section.note && <div className="menu-note">{section.note}</div>}
                </div>
              ))}
            </div>
          ) : (
            <div key="root" className="player-settings-page">
              {pages.map(p => (
                <button key={p.id} role="menuitem" className="player-settings-row"
                  onClick={() => {
                    if (p.sections) { setPage(p.id); return }
                    p.onSelect?.()
                    if (!p.toggle) setOpenState(false)
                  }}>
                  <Icon name={p.icon} size={16} />
                  <span className="grow">{p.label}</span>
                  {p.toggle
                    ? <span className={cx('switch small', p.value === 'On' && 'is-on')} aria-hidden="true"><span /></span>
                    : p.value && <span className="player-settings-value">{p.value}</span>}
                  {p.sections && <Icon name="chevronRight" size={12} stroke={2.4} />}
                  {p.external && <Icon name="external" size={13} />}
                </button>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  )
}
