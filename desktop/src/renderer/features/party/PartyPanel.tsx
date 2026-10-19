import { useEffect, useState } from 'react'
import { createPortal } from 'react-dom'
import { create } from 'zustand'
import { Icon } from '@/components/Icon'
import { answerFollow, party, startParty, leaveParty, joinParty, useParty } from '@/lib/party'
import { toast } from '@/stores/ui'
import { cx } from '@/lib/format'

/**
 * Where modal dialogs go. While the player is full screen only that element
 * is drawn, so a dialog placed anywhere else (like "the host moved on —
 * follow?") would be invisible and the viewer would just sit there.
 */
function useModalHost(): Element {
  const [host, setHost] = useState<Element>(() => document.fullscreenElement ?? document.body)
  useEffect(() => {
    const update = () => setHost(document.fullscreenElement ?? document.body)
    document.addEventListener('fullscreenchange', update)
    update()
    return () => document.removeEventListener('fullscreenchange', update)
  }, [])
  return host
}

/** Starting a party asks first (what it does, who can join), then creates the room. */
export const useStartPartyDialog = create<{ open: boolean }>(() => ({ open: false }))

export function PartyButton() {
  const active = useParty(s => s.active)
  const count = useParty(s => s.peers.length + 1)
  return (
    <button className={cx('pill-btn', active && 'is-open')} aria-label="Watch together" title="Watch together"
      onClick={() => (active ? useParty.setState(s => ({ panelOpen: !s.panelOpen })) : useStartPartyDialog.setState({ open: true }))}>
      <Icon name="people" size={14} /><span>{active ? `${count} watching` : 'Watch Together'}</span>
    </button>
  )
}

/** Side panel in the player: invite link, who's here, host settings. */
export function PartyPanel() {
  const s = useParty()
  if (!s.active || !s.panelOpen) return null
  const roleOf = (id: string) => (id === s.hostId ? 'Host' : id === s.leader ? 'Acting host' : null)
  const canControlPeer = (id: string) => id === s.leader || s.mode === 'everyone' || (s.mode === 'select' && s.allowed.includes(id))
  const people = [{ id: s.me, name: 'You', platform: 'pc', buffering: false, error: null as string | null, gap: null as number | null }, ...s.peers]
  // From the leader's 30-second check: only worth mentioning when noticeable.
  const gapText = (g: number | null) => (g !== null && Math.abs(g) >= 0.5 ? ` · ${Math.abs(g).toFixed(1)}s ${g > 0 ? 'ahead' : 'behind'}` : '')

  return (
    <aside className="party-panel glass-strong" aria-label="Watch party">
      <div className="party-head">
        <div>
          <div className="party-title">Watch party</div>
          <div className="form-hint">{s.status === 'connected' ? `${people.length} watching` : s.status === 'reconnecting' ? 'Reconnecting…' : 'Connecting…'}</div>
        </div>
        <button className="tb-btn" aria-label="Close panel" onClick={() => useParty.setState({ panelOpen: false })}><Icon name="close" size={14} /></button>
      </div>

      <div className="party-section">
        <div className="form-hint">Invite link — anyone with it can join</div>
        <div className="party-link">
          <input className="text-input grow" readOnly value={s.link} onFocus={e => e.currentTarget.select()} aria-label="Invite link" />
          <button className="btn small btn-primary" onClick={() => { navigator.clipboard.writeText(s.link); toast('Invite link copied') }}>Copy</button>
        </div>
      </div>

      <div className="party-section">
        <div className="form-hint">People</div>
        <div className="party-people">
          {people.map(p => (
            <div key={p.id} className="party-person">
              <span className={cx('server-dot', !p.buffering && 'ok', p.buffering && 'testing', p.error && 'bad')} aria-hidden="true" />
              <div className="grow">
                <div>{p.name}{roleOf(p.id) && <span className="device-badge">{roleOf(p.id)}</span>}</div>
                <div className="form-hint">{p.error ?? (p.buffering ? 'Buffering…' : (canControlPeer(p.id) ? 'Can control' : 'Watching') + gapText(p.gap))}</div>
              </div>
              {s.canConfigure && s.mode === 'select' && p.id !== s.me && (
                <button className={cx('btn small', s.allowed.includes(p.id) && 'btn-primary')} onClick={() => party.toggleAllowed(p.id)}>
                  {s.allowed.includes(p.id) ? 'Can control' : 'Allow'}
                </button>
              )}
            </div>
          ))}
        </div>
      </div>

      {s.canConfigure && (
        <div className="party-section">
          <div className="form-hint">Who can control playback</div>
          <div className="segmented small">
            {(['everyone', 'host', 'select'] as const).map(m => (
              <button key={m} className={cx('seg', s.mode === m && 'is-active')} onClick={() => party.configure({ mode: m })}>
                {m === 'everyone' ? 'Everyone' : m === 'host' ? 'Only me' : 'People I pick'}
              </button>
            ))}
          </div>
          <label className="party-check">
            <input type="checkbox" checked={s.waitForAll} onChange={e => party.configure({ waitForAll: e.target.checked })} />
            Wait for anyone buffering <span className="form-hint">(up to 15s)</span>
          </label>
        </div>
      )}

      <div className="party-section">
        <div className="form-hint">Your sync <span className="muted">— only shifts your own player, e.g. if a dub runs a little long</span></div>
        <div className="party-link">
          <button className="btn small" onClick={() => party.nudge(-0.5)}>−0.5s</button>
          <span className="party-offset">{s.offset > 0 ? '+' : ''}{s.offset.toFixed(1)}s</span>
          <button className="btn small" onClick={() => party.nudge(0.5)}>+0.5s</button>
        </div>
      </div>

      <button className="btn small danger" onClick={() => leaveParty()}>Leave party</button>
    </aside>
  )
}

/** Explains Watch Together; the room is only created on Continue. */
export function StartPartyDialog() {
  const open = useStartPartyDialog(s => s.open)
  const host = useModalHost()
  if (!open) return null
  const close = () => useStartPartyDialog.setState({ open: false })
  return createPortal(
    <div className="sheet-backdrop" onMouseDown={close} onKeyDown={e => { if (e.key === 'Escape') close() }}>
      <div className="sheet glass-strong" role="dialog" aria-modal="true" aria-labelledby="start-party-title" aria-describedby="start-party-desc" onMouseDown={e => e.stopPropagation()}>
        <h2 id="start-party-title" className="sheet-title">Watch Together</h2>
        <p id="start-party-desc" className="muted sheet-sub">
          Watch this with friends in sync. Playback, pausing and seeking stay in step for everyone, and the room waits if someone is buffering.
          Continuing creates a room and gives you an invite link. Anyone with the link can join, and everything in the room is end-to-end encrypted.
        </p>
        <div className="sheet-actions">
          <button className="btn" onClick={close}>Cancel</button>
          <button className="btn btn-primary" autoFocus onClick={() => { close(); startParty() }}>Continue</button>
        </div>
      </div>
    </div>,
    host
  )
}

/** Dialog to paste an invite link (also opened by vela://party links). */
export function JoinPartyDialog({ onClose }: { onClose: () => void }) {
  const [text, setText] = useState('')
  return (
    <div className="sheet-backdrop" onMouseDown={onClose}>
      <div className="sheet glass-strong" role="dialog" aria-modal="true" aria-labelledby="join-title" onMouseDown={e => e.stopPropagation()}>
        <h2 id="join-title" className="sheet-title">Join a watch party</h2>
        <p className="muted sheet-sub">Paste the invite link someone sent you.</p>
        <input className="text-input" style={{ width: '100%' }} autoFocus placeholder="https://…/p/…" value={text}
          onChange={e => setText(e.target.value)} onKeyDown={e => { if (e.key === 'Enter' && joinParty(text)) onClose() }} />
        <div className="sheet-actions">
          <button className="btn" onClick={onClose}>Cancel</button>
          <button className="btn btn-primary" onClick={() => { if (joinParty(text)) onClose() }}>Join</button>
        </div>
      </div>
    </div>
  )
}

/** Always-visible party pill (outside the player) + the panel when open. */
export function PartyDock() {
  const s = useParty()
  if (!s.active) return null
  const hostAway = !s.isHost
  return (
    <>
      <button className="party-dock glass-strong" onClick={() => useParty.setState(x => ({ panelOpen: !x.panelOpen }))} aria-label="Watch party">
        <Icon name="people" size={14} />
        <span>{s.status === 'reconnecting' ? 'Reconnecting…' : `${s.peers.length + 1} in party`}</span>
        <span className="muted">{s.isHost ? '· pick something to watch' : hostAway ? '· waiting for the host' : ''}</span>
      </button>
      <div className="party-dock-panel"><PartyPanel /></div>
    </>
  )
}

/** "The host moved on — follow?" Shown to viewers once; "follow" sticks. */
export function FollowPrompt() {
  const prompt = useParty(s => s.prompt)
  const host = useModalHost()
  if (!prompt) return null
  return createPortal(
    <div className="sheet-backdrop">
      <div className="sheet glass-strong" role="alertdialog" aria-modal="true" aria-labelledby="follow-title">
        <h2 id="follow-title" className="sheet-title">{prompt.title ? 'The host started something new' : 'The host went back to browsing'}</h2>
        <p className="muted sheet-sub">
          {prompt.title ? <>They’re now watching <strong>{prompt.title}</strong>.</> : 'They’re picking what to watch next.'}{' '}
          Follow them for the rest of the party, or leave.
        </p>
        <div className="sheet-actions">
          <button className="btn" onClick={() => answerFollow(false)}>Leave party</button>
          <button className="btn btn-primary" onClick={() => answerFollow(true)}>Follow host</button>
        </div>
      </div>
    </div>,
    host
  )
}
