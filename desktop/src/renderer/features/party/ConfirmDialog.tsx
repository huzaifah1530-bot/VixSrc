// Cancel / Continue confirmation, shown before an action with a consequence
// the user might not expect (mainly: leaving a watch party). Rendered into the
// full-screen element when the player is full screen, so it is never hidden.
import { useEffect, useRef } from 'react'
import { createPortal } from 'react-dom'
import { create } from 'zustand'
import { isPartyViewer } from '@/lib/party'
import { useModalHost } from './PartyPanel'

interface ConfirmRequest {
  title: string
  message: string
  confirmLabel: string
  resolve: (ok: boolean) => void
}

const useConfirm = create<{ request: ConfirmRequest | null }>(() => ({ request: null }))

export function confirmAction(title: string, message: string, confirmLabel = 'Continue'): Promise<boolean> {
  // A second request replaces the first; the first counts as cancelled.
  useConfirm.getState().request?.resolve(false)
  return new Promise(resolve => useConfirm.setState({ request: { title, message, confirmLabel, resolve } }))
}

/**
 * Runs `run` straight away unless it would pull this viewer out of a watch
 * party, in which case it asks first. `action` names what the user chose,
 * e.g. "Playing the next episode".
 */
export async function guardPartyLeave(action: string, run: () => void) {
  if (!isPartyViewer()) { run(); return }
  const ok = await confirmAction(
    'Leave the watch party?',
    `${action} will make you leave the party. Continue?`
  )
  if (ok) run()
}

export function ConfirmDialog() {
  const request = useConfirm(s => s.request)
  const host = useModalHost()
  const confirmRef = useRef<HTMLButtonElement>(null)
  useEffect(() => { if (request) confirmRef.current?.focus() }, [request])
  if (!request) return null
  const answer = (ok: boolean) => {
    useConfirm.setState({ request: null })
    request.resolve(ok)
  }
  return createPortal(
    <div className="sheet-backdrop" onMouseDown={() => answer(false)}
      onKeyDown={e => { if (e.key === 'Escape') { e.stopPropagation(); answer(false) } }}>
      <div className="sheet glass-strong" role="alertdialog" aria-modal="true" aria-labelledby="confirm-title" aria-describedby="confirm-desc"
        onMouseDown={e => e.stopPropagation()}>
        <h2 id="confirm-title" className="sheet-title">{request.title}</h2>
        <p id="confirm-desc" className="muted sheet-sub">{request.message}</p>
        <div className="sheet-actions">
          <button className="btn" onClick={() => answer(false)}>Cancel</button>
          <button ref={confirmRef} className="btn btn-primary" onClick={() => answer(true)}>{request.confirmLabel}</button>
        </div>
      </div>
    </div>,
    host
  )
}
