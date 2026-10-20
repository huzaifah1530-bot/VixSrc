import { useEffect, useState } from 'react'
import { Icon } from '@/components/Icon'
import { useLink } from '@/stores/link'
import { cx } from '@/lib/format'

/** Sheet-style dialog with the pairing QR code. */
export function ConnectDialog() {
  const { dialogOpen, status, pairRequestFrom, closeConnect, showQr, pairAnother } = useLink()
  const [now, setNow] = useState(Date.now())
  useEffect(() => {
    if (!dialogOpen) return
    const t = setInterval(() => setNow(Date.now()), 1000)
    const k = (e: KeyboardEvent) => { if (e.key === 'Escape') closeConnect() }
    window.addEventListener('keydown', k)
    return () => { clearInterval(t); window.removeEventListener('keydown', k) }
  }, [dialogOpen, closeConnect])
  if (!dialogOpen) return null
  const pairing = status?.pairing
  const left = pairing ? Math.max(0, Math.round((pairing.expiresAt - now) / 1000)) : 0
  const devices = status?.devices ?? []

  if (!showQr) return (
    <div className="sheet-backdrop" onMouseDown={closeConnect}>
      <div className="sheet glass-strong" role="dialog" aria-modal="true" aria-labelledby="connect-title" onMouseDown={e => e.stopPropagation()}>
        <h2 id="connect-title" className="sheet-title">Your iPhones</h2>
        <p className="muted sheet-sub">Paired phones reconnect on their own when Vela is open on both and they’re on the same Wi-Fi.</p>
        <div className="form-box device-list">
          {devices.map(d => (
            <div key={d.deviceId} className="form-row">
              <div>
                <div className="device-status">
                  <span className={cx('server-dot', d.connected && 'ok')} aria-hidden="true" />
                  {d.name}
                  {d.syncEnabled && <span className="device-badge">SYNC</span>}
                </div>
                <div className="form-hint">{d.connected ? 'Connected' : 'Not connected'}</div>
              </div>
              {d.connected && <button className="btn small" onClick={() => window.vela.link.disconnect(d.deviceId)}>Disconnect</button>}
            </div>
          ))}
        </div>
        <div className="sheet-actions">
          <button className="btn" onClick={() => { closeConnect(); window.vela.window.openSettings() }}>Manage…</button>
          <span className="grow" />
          <button className="btn" onClick={() => pairAnother()}><Icon name="plus" size={13} />Pair Another iPhone</button>
          <button className="btn btn-primary" onClick={closeConnect}>Done</button>
        </div>
      </div>
    </div>
  )

  return (
    <div className="sheet-backdrop" onMouseDown={closeConnect}>
      <div className="sheet glass-strong" role="dialog" aria-modal="true" aria-labelledby="connect-title" onMouseDown={e => e.stopPropagation()}>
        <h2 id="connect-title" className="sheet-title">Connect your iPhone</h2>
        <p className="muted sheet-sub">
          {pairRequestFrom ? `${pairRequestFrom} wants to connect. ` : ''}
          Open Vela on your iPhone, go to Settings › Devices and scan this code.
        </p>
        <div className="qr-frame">
          {pairing && left > 0 ? <img src={pairing.qr} alt="Pairing QR code" /> : (
            <button className="btn" onClick={() => pairAnother()}><Icon name="refresh" size={13} />New code</button>
          )}
        </div>
        <p className="form-hint center">
          {pairing && left > 0 ? `Code expires in ${Math.floor(left / 60)}:${String(left % 60).padStart(2, '0')}` : 'Code expired'}
          {status?.addresses.length ? ` · ${status.deskName} (${status.addresses[0]}:${status.port})` : ''}
        </p>
        {status?.error && <p className="form-hint center danger-text">{status.error}</p>}
        <div className="sheet-actions">
          {devices.length > 0 && (
            <button className="btn" onClick={() => { window.vela.link.cancelPairing(); useLink.setState({ showQr: false, pairRequestFrom: null }) }}>
              <Icon name="chevronLeft" size={13} />Paired iPhones
            </button>
          )}
          <span className="grow" />
          <button className="btn" onClick={closeConnect}>Done</button>
        </div>
      </div>
    </div>
  )
}

/** Confirmation before a phone's data replaces this PC's. */
export function OfferDialog() {
  const offer = useLink(s => s.offer)
  const resolve = useLink(s => s.resolveOffer)
  if (!offer) return null
  return (
    <div className="sheet-backdrop">
      <div className="sheet glass-strong" role="alertdialog" aria-modal="true" aria-labelledby="offer-title">
        <h2 id="offer-title" className="sheet-title">Replace this PC’s data?</h2>
        <p className="muted sheet-sub">
          {offer.name} wants to copy its API key, servers, favourites, history and watch positions to this PC.
          Saved data on this PC will be replaced. Device settings like appearance stay as they are.
        </p>
        {!offer.doc && <p className="form-hint danger-text">The data received was invalid, so nothing can be copied.</p>}
        <div className="sheet-actions">
          <button className="btn" onClick={() => resolve(false)}>Cancel</button>
          <button className="btn btn-primary" disabled={!offer.doc} onClick={() => resolve(true)}>Replace</button>
        </div>
      </div>
    </div>
  )
}
