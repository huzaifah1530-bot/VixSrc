// Small status pop-up that drops in from the top (same scale as the player's
// 2× badge). Used for refreshes: "Syncing…" with a spinner, then a short
// "Up to date" or the reason it failed.
import { create } from 'zustand'
import { Icon } from './Icon'
import { cx } from '@/lib/format'

type PillState = 'busy' | 'done' | 'error'
interface Pill { id: number; text: string; state: PillState }

const usePill = create<{ pill: Pill | null; leaving: boolean }>(() => ({ pill: null, leaving: false }))
let nextId = 1
let hideTimer: ReturnType<typeof setTimeout> | undefined

function hideLater(id: number, ms: number) {
  clearTimeout(hideTimer)
  hideTimer = setTimeout(() => {
    if (usePill.getState().pill?.id !== id) return
    usePill.setState({ leaving: true })
    hideTimer = setTimeout(() => { if (usePill.getState().pill?.id === id) usePill.setState({ pill: null, leaving: false }) }, 260)
  }, ms)
}

/** Shows a busy pill; call the returned function with the outcome. */
export function showStatus(text: string): (outcome: { ok: boolean; text: string }) => void {
  const id = nextId++
  clearTimeout(hideTimer)
  usePill.setState({ pill: { id, text, state: 'busy' }, leaving: false })
  // Never leave a spinner up forever.
  hideLater(id, 20_000)
  return ({ ok, text }) => {
    if (usePill.getState().pill?.id !== id) return
    usePill.setState({ pill: { id, text, state: ok ? 'done' : 'error' }, leaving: false })
    hideLater(id, ok ? 1400 : 3200)
  }
}

export function StatusPill() {
  const { pill, leaving } = usePill()
  if (!pill) return null
  return (
    <div key={pill.id} className={cx('status-pill glass-strong', leaving && 'is-leaving', `is-${pill.state}`)} role="status" aria-live="polite">
      {pill.state === 'busy' ? <span className="status-pill-spinner" aria-hidden="true" />
        : <span key={pill.state} className="status-pill-icon"><Icon name={pill.state === 'done' ? 'check' : 'info'} size={13} stroke={2.6} /></span>}
      <span key={pill.text} className="status-pill-text">{pill.text}</span>
    </div>
  )
}
