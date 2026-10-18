import { useState } from 'react'
import { Icon } from '@/components/Icon'
import { party, startParty, leaveParty, joinParty, useParty } from '@/lib/party'
import { toast } from '@/stores/ui'
import { cx } from '@/lib/format'

export function PartyButton() {
  const active = useParty(s => s.active)
  const count = useParty(s => s.peers.length + 1)
  return (
    <button className={cx('pill-btn', active && 'is-open')} aria-label="Watch together" title="Watch together"
      onClick={() => (active ? useParty.setState(s => ({ panelOpen: !s.panelOpen })) : startParty())}>
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
  const people = [{ id: s.me, name: 'You', platform: 'pc', buffering: false, error: null as string | null }, ...s.peers]

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
                <div className="form-hint">{p.error ?? (p.buffering ? 'Buffering…' : canControlPeer(p.id) ? 'Can control' : 'Watching')}</div>
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
