// Preferences window (auxiliary window per the macOS HIG): toolbar-style
// pane switcher, grouped form rows, changes apply immediately.
import { useEffect, useState } from 'react'
import type { StreamServer } from '@shared/types'
import { Icon, type IconName } from '@/components/Icon'
import { Toast } from '@/components/Media'
import { TrafficLights, useWindowFocusClass } from '@/components/Chrome'
import { CAPTION_SIZES, DEFAULT_ANIME_SERVERS, DEFAULT_SERVERS, SEEK_OPTIONS, useSettings } from '@/stores/settings'
import { useLibrary } from '@/stores/library'
import { applyBackup, buildBackup, exportBackup, importBackup } from '@/lib/backup'
import type { AccountApi } from '@shared/account'
import { backupHash, hashKey, revisionKey } from '@/lib/accountBackup'
import { toast } from '@/stores/ui'
import { cx, formatTime, uuid } from '@/lib/format'
import type { UpdateCheckResult } from '@shared/types'
import { startLinkStatus, useLink } from '@/stores/link'

type Pane = 'account' | 'general' | 'servers' | 'anime' | 'devices' | 'data'
const panes: { id: Pane; label: string; icon: IconName }[] = [
  { id: 'account', label: 'Account', icon: 'people' },
  { id: 'general', label: 'General', icon: 'gear' },
  { id: 'servers', label: 'Servers', icon: 'server' },
  { id: 'anime', label: 'Anime', icon: 'sparkles' },
  { id: 'devices', label: 'Devices', icon: 'phone' },
  { id: 'data', label: 'Data', icon: 'clock' }
]

export function SettingsWindow() {
  const [pane, setPane] = useState<Pane>('account')
  const perf = useSettings(s => s.performanceMode)
  const ultra = useSettings(s => s.ultraPerformanceMode)
  useWindowFocusClass()
  useEffect(() => { document.title = 'Vela Settings' }, [])
  useEffect(() => { document.body.classList.toggle('perf', perf && !ultra); document.body.classList.toggle('ultra', ultra) }, [perf, ultra])
  useEffect(() => {
    const k = (e: KeyboardEvent) => { if (e.key === 'Escape' || (e.ctrlKey && e.key.toLowerCase() === 'w')) window.vela.window.close() }
    window.addEventListener('keydown', k)
    return () => window.removeEventListener('keydown', k)
  }, [])

  return (
    <div className="prefs">
      <header className="prefs-bar">
        <TrafficLights />
        <div className="prefs-title">{panes.find(p => p.id === pane)?.label}</div>
        <div className="prefs-tabs" role="tablist">
          {panes.map(p => (
            <button key={p.id} role="tab" aria-selected={pane === p.id} className={cx('prefs-tab', pane === p.id && 'is-active')} onClick={() => setPane(p.id)}>
              <Icon name={p.icon} size={18} />{p.label}
            </button>
          ))}
        </div>
      </header>
      <main className="prefs-body" role="tabpanel">
        {pane === 'account' && <AccountPane />}
        {pane === 'general' && <General />}
        {pane === 'servers' && <Servers kind="regular" />}
        {pane === 'anime' && <AnimePane />}
        {pane === 'devices' && <DevicesPane />}
        {pane === 'data' && <DataPane />}
      </main>
      <Toast />
    </div>
  )
}

function Group({ title, footer, children }: { title?: string; footer?: string; children: React.ReactNode }) {
  return (
    <section className="form-group">
      {title && <h3 className="form-title">{title}</h3>}
      <div className="form-box">{children}</div>
      {footer && <p className="form-footer">{footer}</p>}
    </section>
  )
}
function Field({ label, children, hint }: { label: string; children: React.ReactNode; hint?: string }) {
  return <div className="form-row"><div><div>{label}</div>{hint && <div className="form-hint">{hint}</div>}</div><div className="form-control">{children}</div></div>
}
function Toggle({ checked, onChange, label }: { checked: boolean; onChange: (v: boolean) => void; label: string }) {
  return <button role="switch" aria-checked={checked} aria-label={label} className={cx('switch', checked && 'is-on')} onClick={() => onChange(!checked)}><span /></button>
}

const accountApi = (window.vela as typeof window.vela & { account: AccountApi }).account

function AccountPane() {
  const [username, setUsername] = useState<string | null>(null)
  const [name, setName] = useState('')
  const [pin, setPin] = useState('')
  const [confirmPin, setConfirmPin] = useState('')
  const [creating, setCreating] = useState(false)
  const [recovery, setRecovery] = useState(false)
  const [recoveryInput, setRecoveryInput] = useState('')
  const [recoveryCode, setRecoveryCode] = useState<string | null>(null)
  const [newName, setNewName] = useState('')
  const [newPin, setNewPin] = useState('')
  const [devices, setDevices] = useState<{ device_id: string; device_name: string; created_at: number; current: boolean }[]>([])
  const [deleteConfirm, setDeleteConfirm] = useState(false)
  const [downloadConfirm, setDownloadConfirm] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  useEffect(() => { accountApi.call('status').finally(() => accountApi.status().then(s => setUsername(s.username))) }, [])
  useEffect(() => { if (username) accountApi.call('devices').then(r => { if (r.status === 200) setDevices(r.data.devices ?? []) }) }, [username])
  const message = (code: string) => ({
    invalid_credentials: 'Incorrect username or PIN.', username_taken: 'That username is already taken.',
    invalid_pin: 'Choose a 4- or 6-digit PIN that is not a simple sequence.',
    temporarily_locked: 'Too many attempts. Try again later.', rate_limited: 'Too many attempts. Try again later.',
    conflict: 'Cloud data changed on another device. Download it before saving again.',
    unauthorized: 'Your session expired. Sign in again.', unavailable: 'Vela Cloud is unavailable.'
  }[code] ?? `Cloud request failed (${code}).`)
  const run = async (action: string, body?: Record<string, unknown>) => {
    setBusy(true); setError(null)
    try {
      const result = await accountApi.call(action, body)
      if (result.status < 200 || result.status >= 300) { setError(message(result.data.error?.code ?? 'unavailable')); return null }
      setUsername((await accountApi.status()).username)
      return result.data
    } catch { setError('Vela Cloud is unavailable.'); return null }
    finally { setBusy(false) }
  }
  return <div aria-busy={busy}>
    {!username ? <>
      <Group title="Vela Account" footer="Sign In and Create Account are separate actions. A mistyped username in Sign In will never create an account.">
        <Field label="Action"><div className="segmented small"><button className={cx('seg', !creating && 'is-active')} onClick={() => setCreating(false)}>Sign In</button><button className={cx('seg', creating && 'is-active')} onClick={() => setCreating(true)}>Create Account</button></div></Field>
        <Field label="Username"><input className="text-input" value={name} onChange={e => setName(e.target.value)} autoCapitalize="off" autoCorrect="off" /></Field>
        <Field label={creating ? 'Choose a 4- or 6-digit PIN' : 'PIN'}><input className="text-input" type="password" inputMode="numeric" value={pin} onChange={e => setPin(e.target.value)} /></Field>
        {creating && <Field label="Confirm PIN"><input className="text-input" type="password" inputMode="numeric" value={confirmPin} onChange={e => setConfirmPin(e.target.value)} /></Field>}
        <Field label=""><button className="btn btn-primary small" disabled={busy || !name || !pin || (creating && !confirmPin)} onClick={async () => {
          if (creating && pin !== confirmPin) { setError('The PINs do not match.'); return }
          const result = await run(creating ? 'register' : 'login', { username: name, pin, deviceName: 'Vela Windows PC' })
          if (result) {
            setRecoveryCode(result.recoveryCode ?? null); setPin(''); setConfirmPin('')
            if (creating) { const { accountKey } = await accountApi.status(); if (accountKey) localStorage.setItem(revisionKey(accountKey), '0') }
          }
        }}>{creating ? 'Confirm New Account' : 'Sign In'}</button></Field>
      </Group>
      <Group title="Recovery" footer="There is no email reset. Save the recovery code shown when you create an account.">
        <Field label="Have a recovery code?"><Toggle checked={recovery} onChange={setRecovery} label="Use recovery code" /></Field>
        {recovery && <>
          <Field label="Recovery code"><input className="text-input" value={recoveryInput} onChange={e => setRecoveryInput(e.target.value)} /></Field>
          <Field label=""><button className="btn small" disabled={busy || !name || !pin || !recoveryInput} onClick={async () => {
            const result = await run('recover', { username: name, pin, recoveryCode: recoveryInput, deviceName: 'Vela Windows PC' })
            if (result) setRecoveryCode(result.recoveryCode ?? null)
          }}>Reset PIN and Sign In</button></Field>
        </>}
      </Group>
    </> : <>
      <Group title="Vela Account"><Field label={username} hint="Signed in on this PC"><Icon name="check" size={20} /></Field></Group>
      <Group title="Cloud Data" footer="Download replaces this PC's local data. Signing out keeps your local data; deleting the account removes its cloud data.">
        <Field label="Back up this PC"><button className="btn small" disabled={busy} onClick={async () => {
          const current = await accountApi.call('download')
          if (current.status !== 200 && current.status !== 404) { setError(message(current.data.error?.code ?? 'unavailable')); return }
          const revision = current.status === 200 ? current.data.revision : 0
          const result = await run('upload', { baseRevision: revision, payload: JSON.parse(buildBackup()) })
          if (result) {
            const { accountKey } = await accountApi.status()
            if (accountKey) {
              const payload = JSON.parse(buildBackup()) as Record<string, unknown>
              localStorage.setItem(revisionKey(accountKey), String(result.revision))
              localStorage.setItem(hashKey(accountKey), await backupHash(payload))
            }
            toast('Cloud backup saved')
          }
        }}>Back Up Now</button></Field>
        <Field label="Download from cloud">{downloadConfirm ? <><button className="btn small danger" onClick={async () => { const result = await run('download'); if (result?.payload) { applyBackup(JSON.stringify(result.payload)); const { accountKey } = await accountApi.status(); if (accountKey) { localStorage.setItem(revisionKey(accountKey), String(result.revision)); localStorage.setItem(hashKey(accountKey), await backupHash(result.payload)) } toast('Cloud data downloaded') } setDownloadConfirm(false) }}>Replace local data</button><button className="btn small" onClick={() => setDownloadConfirm(false)}>Cancel</button></> : <button className="btn small" onClick={() => setDownloadConfirm(true)}>Download…</button>}</Field>
      </Group>
      <Group title="Change Username"><Field label="New username"><input className="text-input" value={newName} onChange={e => setNewName(e.target.value)} /></Field><Field label=""><button className="btn small" disabled={busy || !newName} onClick={async () => { if (await run('rename', { next: newName })) setNewName('') }}>Change Username</button></Field></Group>
      <Group title="Change PIN"><Field label="Current PIN"><input className="text-input" type="password" inputMode="numeric" value={pin} onChange={e => setPin(e.target.value)} /></Field><Field label="New 4- or 6-digit PIN"><input className="text-input" type="password" inputMode="numeric" value={newPin} onChange={e => setNewPin(e.target.value)} /></Field><Field label=""><button className="btn small" disabled={busy || !pin || !newPin} onClick={async () => { if (await run('changePin', { currentPin: pin, newPin })) { setPin(''); setNewPin(''); toast('PIN changed') } }}>Change PIN</button></Field></Group>
      <Group title="Signed-In Devices">
        {devices.map(d => <Field key={d.device_id} label={`${d.device_name}${d.current ? ' (this PC)' : ''}`} hint={new Date(d.created_at).toLocaleDateString()}><button className="btn small danger" onClick={async () => { if (await run(`revoke:${d.device_id}`)) { const list = await run('devices'); setDevices(list?.devices ?? []) } }}>Sign Out</button></Field>)}
        <Field label=""><button className="btn small" onClick={async () => { const list = await run('devices'); setDevices(list?.devices ?? []) }}>Refresh</button></Field>
      </Group>
      <Group title="Account Actions">
        <Field label="This PC"><button className="btn small" onClick={() => run('logout')}>Sign Out</button></Field>
        <Field label="Delete account" hint="Permanently removes cloud data and all signed-in sessions">{deleteConfirm ? <><input className="text-input" type="password" inputMode="numeric" value={pin} placeholder="Confirm PIN" onChange={e => setPin(e.target.value)} /><button className="btn small danger" disabled={!pin || busy} onClick={() => run('deleteAccount', { pin })}>Delete Account</button><button className="btn small" onClick={() => setDeleteConfirm(false)}>Cancel</button></> : <button className="btn small danger" onClick={() => setDeleteConfirm(true)}>Delete…</button>}</Field>
      </Group>
    </>}
    {recoveryCode && <Group title="Save Your Recovery Code" footer="Keep this code somewhere safe. It is shown only once and replaces any previous recovery code."><Field label={recoveryCode}><button className="btn small" onClick={() => navigator.clipboard.writeText(recoveryCode)}>Copy</button><button className="btn small" onClick={() => setRecoveryCode(null)}>I've Saved It</button></Field></Group>}
    {error && <p role="alert" className="form-footer">{error}</p>}
  </div>
}

function General() {
  const s = useSettings()
  const [key, setKey] = useState(s.credential)
  const [update, setUpdate] = useState<UpdateCheckResult | null>(null)
  const [checking, setChecking] = useState(false)
  const [progress, setProgress] = useState<number | null>(null)
  useEffect(() => setKey(s.credential), [s.credential])
  useEffect(() => window.vela.on('update-download-progress', setProgress), [])

  const check = async () => { setChecking(true); setUpdate(await window.vela.updater.check()); setChecking(false) }
  return (
    <>
      <Group title="TMDB" footer="Leave empty to use Vela's built-in key. Accepts a v3 API key or a v4 read access token.">
        <Field label="API key or token">
          <input className="text-input" type="password" value={key} placeholder="Built-in key" onChange={e => setKey(e.target.value)}
            onBlur={() => key !== s.credential && (s.set({ credential: key.trim() }), toast('TMDB key saved'))} spellCheck={false} />
        </Field>
      </Group>
      <Group title="Playback">
        <Field label="Skip interval" hint="Arrow keys, J / L and the skip buttons">
          <div className="segmented small">{SEEK_OPTIONS.map(v => <button key={v} className={cx('seg', s.seekInterval === v && 'is-active')} onClick={() => s.set({ seekInterval: v })}>{v}s</button>)}</div>
        </Field>
        <Field label="Automatically skip intros" hint="When intro times are known from SkipDB, TheIntroDB, or AniSkip. Manual Skip Intro is always offered. In a watch party only the host skips.">
          <Toggle label="Automatically skip intros" checked={!!s.autoSkipIntro} onChange={v => s.set({ autoSkipIntro: v })} />
        </Field>
        <Field label="Caption size" hint="Subtitles drawn by Vela’s player">
          <div className="segmented small">{CAPTION_SIZES.map(c => <button key={c.v} className={cx('seg', (s.captionScale ?? 1) === c.v && 'is-active')} onClick={() => s.set({ captionScale: c.v })}>{c.label}</button>)}</div>
        </Field>
      </Group>
      <Group title="Custom intro times" footer="Set these in the Intro start / end boxes on a show’s or anime’s page (00:00 and 00:00 = off). They apply to every episode and replace found intro times. Skip data: SkipDB (ODbL 1.0), with TheIntroDB / AniSkip fallback.">
        {Object.keys(s.introOverrides ?? {}).length === 0 && <div className="form-row"><span className="muted">None yet.</span></div>}
        {Object.entries(s.introOverrides ?? {}).map(([key, o]) => (
          <Field key={key} label={o.title || key} hint={`${o.start == null ? '–' : formatTime(o.start)} – ${o.end == null ? '–' : formatTime(o.end)}${o.start == null || o.end == null ? ' (incomplete, not used)' : ''}`}>
            <button className="tb-btn danger" aria-label={`Remove custom intro for ${o.title || key}`} onClick={() => {
              const next = { ...s.introOverrides }; delete next[key]; s.set({ introOverrides: next })
            }}><Icon name="trash" /></button>
          </Field>
        ))}
      </Group>
      <Group title="Appearance" footer="Performance modes turn off the glass blur on slower PCs. Ultra also removes translucency.">
        <Field label="Poster size">
          <div className="segmented small">{(['compact', 'large'] as const).map(v => <button key={v} className={cx('seg', s.cardSize === v && 'is-active')} onClick={() => s.set({ cardSize: v })}>{v === 'compact' ? 'Compact' : 'Large'}</button>)}</div>
        </Field>
        <Field label="Performance mode"><Toggle label="Performance mode" checked={s.performanceMode} onChange={v => s.set({ performanceMode: v, ultraPerformanceMode: v ? s.ultraPerformanceMode : false })} /></Field>
        <Field label="Ultra performance mode"><Toggle label="Ultra performance mode" checked={s.ultraPerformanceMode} onChange={v => s.set({ ultraPerformanceMode: v, performanceMode: v || s.performanceMode })} /></Field>
      </Group>
      <Group title="Updates">
        <Field label={`Vela ${window.vela.version}`} hint={update?.error ?? (update ? (update.updateAvailable ? `Version ${update.latestVersion} is available.${update.notes ? ' ' + update.notes : ''}` : 'You’re up to date.') : undefined)}>
          {update?.updateAvailable
            ? <button className="btn btn-primary small" disabled={progress !== null} onClick={async () => { setProgress(0); const r = await window.vela.updater.apply(update.downloadUrl, update.releaseUrl); if (!r.ok) { setProgress(null); toast(r.error ?? 'Update failed') } }}>
                {progress !== null ? `Downloading ${Math.round(progress * 100)}%` : 'Install Update'}
              </button>
            : <button className="btn small" disabled={checking} onClick={check}>{checking ? 'Checking…' : 'Check for Updates'}</button>}
        </Field>
      </Group>
    </>
  )
}

function Servers({ kind }: { kind: 'regular' | 'anime' }) {
  const list = useSettings(s => (kind === 'anime' ? s.animeServers : s.servers))
  const set = useSettings(s => s.set)
  const disabled = useSettings(s => kind === 'anime' && !s.animeEnabled)
  const [editing, setEditing] = useState<{ index: number | null; name: string; base: string } | null>(null)
  const [status, setStatus] = useState<Record<string, boolean | 'testing'>>({})
  const save = (next: StreamServer[]) => set(kind === 'anime' ? { animeServers: next } : { servers: next })

  const test = async (s: StreamServer) => {
    setStatus(x => ({ ...x, [s.id]: 'testing' }))
    const ok = await window.vela.checkServer(kind === 'anime' ? s.base : s.base.replace(/\/+$/, '') + '/movie/550')
    setStatus(x => ({ ...x, [s.id]: ok }))
  }
  const move = (i: number, d: number) => { const n = [...list]; const [x] = n.splice(i, 1); n.splice(i + d, 0, x); save(n) }
  const commit = () => {
    if (!editing) return
    const name = editing.name.trim(), base = editing.base.trim()
    if (!name || !/^https:\/\/[^\s]+$/i.test(base)) { toast('Enter a name and an https:// address'); return }
    const n = [...list]
    if (editing.index === null) n.push({ id: uuid(), name, base }); else n[editing.index] = { ...n[editing.index], name, base }
    save(n); setEditing(null)
  }

  return (
    <Group
      title={kind === 'anime' ? 'Anime servers' : 'Stream servers'}
      footer={kind === 'anime'
        ? 'Sites that use the AnimeKai layout. The first server feeds the Anime catalogue.'
        : 'Each server is tried as <address>/movie/<id> or /tv/<id>/<season>/<episode>. VixSrc plays in the native player; others open their own web player.'}
    >
      <div className={cx('server-list', disabled && 'is-disabled')}>
        {list.map((s, i) => (
          <div key={s.id} className="server-row">
            <span className={cx('server-dot', status[s.id] === true && 'ok', status[s.id] === false && 'bad', status[s.id] === 'testing' && 'testing')} aria-label={status[s.id] === true ? 'Reachable' : status[s.id] === false ? 'Unreachable' : 'Not tested'} />
            <div className="server-text"><div>{s.name}</div><div className="form-hint clamp-1">{s.base}</div></div>
            <button className="tb-btn" aria-label={`Move ${s.name} up`} disabled={i === 0} onClick={() => move(i, -1)}><Icon name="chevronLeft" className="rot90" /></button>
            <button className="tb-btn" aria-label={`Move ${s.name} down`} disabled={i === list.length - 1} onClick={() => move(i, 1)}><Icon name="chevronRight" className="rot90" /></button>
            <button className="btn small" onClick={() => test(s)}>Test</button>
            <button className="btn small" onClick={() => setEditing({ index: i, name: s.name, base: s.base })}>Edit</button>
            <button className="tb-btn danger" aria-label={`Delete ${s.name}`} onClick={() => save(list.filter((_, j) => j !== i))}><Icon name="trash" /></button>
          </div>
        ))}
        {editing && (
          <div className="server-row editing">
            <input className="text-input" placeholder="Name" value={editing.name} autoFocus onChange={e => setEditing({ ...editing, name: e.target.value })} />
            <input className="text-input grow" placeholder="https://" value={editing.base} onChange={e => setEditing({ ...editing, base: e.target.value })} onKeyDown={e => e.key === 'Enter' && commit()} spellCheck={false} />
            <button className="btn btn-primary small" onClick={commit}>Save</button>
            <button className="btn small" onClick={() => setEditing(null)}>Cancel</button>
          </div>
        )}
        <div className="server-actions">
          <button className="btn small" onClick={() => setEditing({ index: null, name: '', base: 'https://' })}><Icon name="plus" size={12} />Add server</button>
          <button className="btn small" onClick={() => { save(kind === 'anime' ? DEFAULT_ANIME_SERVERS : DEFAULT_SERVERS); toast('Restored defaults') }}>Restore defaults</button>
        </div>
      </div>
    </Group>
  )
}

function AnimePane() {
  const enabled = useSettings(s => s.animeEnabled)
  const set = useSettings(s => s.set)
  return (
    <>
      <Group footer="Turning anime off hides the Anime section. Home only ever shows TMDB titles, with anime filtered out while this is on.">
        <Field label="Anime"><Toggle label="Anime" checked={enabled} onChange={v => set({ animeEnabled: v })} /></Field>
      </Group>
      <Servers kind="anime" />
    </>
  )
}

function DataPane() {
  const clearSearches = useLibrary(s => s.clearSearches)
  const replaceAll = useLibrary(s => s.replaceAll)
  const [confirm, setConfirm] = useState(false)
  return (
    <>
      <Group title="Backup" footer="Includes your TMDB key, favourites, history, watch positions, searches, servers and settings. Works with Vela on iOS.">
        <Field label="Export backup"><button className="btn small" onClick={exportBackup}>Export…</button></Field>
        <Field label="Import backup" hint="Replaces everything on this PC"><button className="btn small" onClick={importBackup}>Import…</button></Field>
      </Group>
      <Group title="History">
        <Field label="Recent searches"><button className="btn small" onClick={() => { clearSearches(); clearSearches(true); toast('Searches cleared') }}>Clear</button></Field>
        <Field label="Watch history" hint="Continue watching and saved positions">
          {confirm
            ? <><button className="btn small danger" onClick={() => { replaceAll({ recents: [], watchProgress: [] }); setConfirm(false); toast('History cleared') }}>Clear history</button><button className="btn small" onClick={() => setConfirm(false)}>Cancel</button></>
            : <button className="btn small" onClick={() => setConfirm(true)}>Clear…</button>}
        </Field>
      </Group>
    </>
  )
}

function DevicesPane() {
  const status = useLink(s => s.status)
  const [confirm, setConfirm] = useState<{ id: string; dir: 'to' | 'from' } | null>(null)
  const [forget, setForget] = useState<string | null>(null)
  useEffect(() => startLinkStatus(), [])
  const ago = (t: number | null) => {
    if (!t) return 'never'
    const m = Math.round((Date.now() - t) / 60000)
    return m < 1 ? 'just now' : m < 60 ? `${m} min ago` : m < 1440 ? `${Math.round(m / 60)} h ago` : new Date(t).toLocaleDateString()
  }
  return (
    <>
      <Group title="This PC" footer="Vela listens on your local network while it’s open. Your iPhone finds it automatically; nothing goes through the internet. Windows may ask to allow Vela through the firewall on private networks.">
        <Field label={status?.deskName ?? '…'} hint={status ? (status.listening ? `Listening on ${status.addresses.join(', ') || 'no network'} · port ${status.port}` : status.error ?? 'Starting…') : undefined}>
          <button className="btn btn-primary small" onClick={() => { window.vela.showMainWindow(); window.vela.link.startPairing().then(() => window.vela.window.close()) }}>Connect iPhone…</button>
        </Field>
      </Group>
      <Group title="Paired devices" footer="Turning sync off keeps the pairing. Forgetting a device means it has to scan a new code; data already copied stays on this PC.">
        {!status?.devices.length && <div className="form-row"><span className="muted">No paired devices yet.</span></div>}
        {status?.devices.map(d => (
          <div key={d.deviceId}>
            <div className="form-row">
              <div>
                <div className="device-status">
                  <span className={cx('server-dot', d.connected && 'ok')} aria-hidden="true" />
                  {d.name}
                  {d.syncEnabled && <span className="device-badge">SYNC</span>}
                </div>
                <div className="form-hint">{d.connected ? 'Connected' : `Last seen ${ago(d.lastSeen)}`} · {d.syncEnabled ? `Synced ${ago(d.lastSync)}` : 'Sync off'}</div>
              </div>
              <div className="form-control">
                {d.connected && <button className="btn small" onClick={() => window.vela.link.disconnect(d.deviceId)}>Disconnect</button>}
                {forget === d.deviceId
                  ? <><button className="btn small danger" onClick={() => { window.vela.link.forget(d.deviceId); setForget(null) }}>Forget</button><button className="btn small" onClick={() => setForget(null)}>Cancel</button></>
                  : <button className="btn small" onClick={() => setForget(d.deviceId)}>Forget…</button>}
              </div>
            </div>
            <Field label="Keep saved data in sync"><Toggle label={`Sync with ${d.name}`} checked={d.syncEnabled} onChange={v => window.vela.link.update(d.deviceId, { syncEnabled: v })} /></Field>
            <Field label="Allow automatic reconnect" hint="When off, the phone has to connect from its Devices screen"><Toggle label="Automatic reconnect" checked={d.autoReconnect} onChange={v => window.vela.link.update(d.deviceId, { autoReconnect: v })} /></Field>
            <Field label="Copy saved data" hint={d.connected ? 'Replaces the other device’s data with a fresh copy' : 'Connect the phone first'}>
              {confirm?.id === d.deviceId ? (
                <>
                  <span className="form-hint">{confirm.dir === 'from' ? 'Replace this PC’s data?' : `${d.name} will ask to confirm`}</span>
                  <button className="btn small btn-primary" onClick={() => { window.vela.link.action(confirm.dir === 'to' ? 'fresh-copy-to' : 'fresh-copy-from', d.deviceId); setConfirm(null) }}>Copy</button>
                  <button className="btn small" onClick={() => setConfirm(null)}>Cancel</button>
                </>
              ) : (
                <>
                  <button className="btn small" disabled={!d.connected} onClick={() => setConfirm({ id: d.deviceId, dir: 'to' })}>This PC → {d.name}</button>
                  <button className="btn small" disabled={!d.connected} onClick={() => setConfirm({ id: d.deviceId, dir: 'from' })}>{d.name} → This PC</button>
                </>
              )}
            </Field>
            <Field label="Sync now"><button className="btn small" disabled={!d.connected || !d.syncEnabled} onClick={() => { window.vela.link.action('sync-now', d.deviceId); toast('Syncing…') }}><Icon name="sync" size={12} />Sync now</button></Field>
          </div>
        ))}
      </Group>
    </>
  )
}
