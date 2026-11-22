// Cloud sync status shared between the main window (which runs the sync) and
// the Settings window (which shows it). The two windows only share
// localStorage, so the status and "sync now" requests travel through it.
export type SyncState = 'idle' | 'syncing' | 'synced' | 'offline' | 'error'
export interface SyncStatus { state: SyncState; at: number; detail?: string }

const STATUS_KEY = 'vela_cloud_sync_status'
const REQUEST_KEY = 'vela_cloud_sync_request'

export function readSyncStatus(): SyncStatus {
  try {
    const s = JSON.parse(localStorage.getItem(STATUS_KEY) ?? 'null') as SyncStatus | null
    if (s && typeof s.state === 'string') return s
  } catch { /* fall through */ }
  return { state: 'idle', at: 0 }
}

export function writeSyncStatus(status: SyncStatus) {
  localStorage.setItem(STATUS_KEY, JSON.stringify(status))
  window.dispatchEvent(new CustomEvent('vela-sync-status', { detail: status }))
}

export function onSyncStatus(cb: (s: SyncStatus) => void): () => void {
  const local = (e: Event) => cb((e as CustomEvent<SyncStatus>).detail)
  const storage = (e: StorageEvent) => { if (e.key === STATUS_KEY) cb(readSyncStatus()) }
  window.addEventListener('vela-sync-status', local)
  window.addEventListener('storage', storage)
  return () => { window.removeEventListener('vela-sync-status', local); window.removeEventListener('storage', storage) }
}

/** Asks the main window to sync now (works from the Settings window too). */
export function requestSync() {
  localStorage.setItem(REQUEST_KEY, String(Date.now()))
  window.dispatchEvent(new CustomEvent('vela-sync-request'))
}

export function onSyncRequest(cb: () => void): () => void {
  const local = () => cb()
  const storage = (e: StorageEvent) => { if (e.key === REQUEST_KEY) cb() }
  window.addEventListener('vela-sync-request', local)
  window.addEventListener('storage', storage)
  return () => { window.removeEventListener('vela-sync-request', local); window.removeEventListener('storage', storage) }
}

export function describeSync(s: SyncStatus): string {
  switch (s.state) {
    case 'syncing': return 'Syncing…'
    case 'synced': return `Synced ${ago(s.at)}`
    case 'offline': return 'Offline. Vela will sync when you’re back online.'
    case 'error': return s.detail ?? 'Last sync failed'
    default: return 'Not synced yet'
  }
}

function ago(t: number) {
  const m = Math.round((Date.now() - t) / 60000)
  return m < 1 ? 'just now' : m < 60 ? `${m} min ago` : m < 1440 ? `${Math.round(m / 60)} h ago` : new Date(t).toLocaleDateString()
}
