import type { AccountApi } from '@shared/account'
import { validateDoc } from '@shared/sync'
import { localDoc, mergeRemote, onLocalChange } from './sync'
import { buildBackup } from './backup'
import { backupHash, hashKey, revisionKey } from './accountBackup'
import { onSyncRequest, writeSyncStatus } from './syncStatus'
import { showStatus } from '@/components/StatusPill'
const account = (window.vela as typeof window.vela & { account: AccountApi }).account
let timer: ReturnType<typeof setTimeout> | undefined
let busy = false
let pending = false
let pendingVisible = false

/** Outcome of one sync attempt, for the status pill and the Account pane. */
type Outcome = { ok: true } | { ok: false; offline: boolean; detail: string }
const failed = (status: number): Outcome => ({
  ok: false,
  offline: status === 503,
  detail: status === 503 ? 'Vela Cloud is unavailable' : `Sync failed (${status})`
})

/** `visible`: the user asked (refresh) or the app just opened, so show the pill. */
async function sync(visible = false) {
  if (busy) { pending = true; pendingVisible ||= visible; return }
  busy = true
  let finish: ReturnType<typeof showStatus> | null = null
  try {
    if (!(await account.status()).username) return
    if (visible) finish = showStatus('Syncing with Vela Cloud…')
    writeSyncStatus({ state: 'syncing', at: Date.now() })
    const outcome = await syncOnce()
    if (outcome.ok) {
      writeSyncStatus({ state: 'synced', at: Date.now() })
      finish?.({ ok: true, text: 'Up to date' })
    } else {
      writeSyncStatus({ state: outcome.offline ? 'offline' : 'error', at: Date.now(), detail: outcome.detail })
      finish?.({ ok: false, text: outcome.detail })
    }
  } catch {
    // Offline is normal; the next local edit or foreground poll retries.
    writeSyncStatus({ state: 'offline', at: Date.now(), detail: 'You’re offline' })
    finish?.({ ok: false, text: 'You’re offline' })
  } finally {
    busy = false
    if (pending) {
      const again = pendingVisible
      pending = false
      pendingVisible = false
      schedule(1000, again)
    }
  }
}

async function syncOnce(): Promise<Outcome> {
  for (let attempt = 0; attempt < 3; attempt++) {
    const incoming = await account.call('downloadShared')
    if (incoming.status !== 200 && incoming.status !== 404) return failed(incoming.status)
    const revision = incoming.status === 200 ? incoming.data.revision : 0
    const remote = incoming.status === 200 ? validateDoc(incoming.data.payload) : null
    if (incoming.status === 200 && !remote) return { ok: false, offline: false, detail: 'Cloud data could not be read' }
    if (remote) mergeRemote(remote)
    const saved = await account.call('uploadShared', { baseRevision: revision, payload: localDoc() })
    if (saved.status === 200) { await autoBackup(); return { ok: true } }
    if (saved.status !== 409) return failed(saved.status)
  }
  return { ok: false, offline: false, detail: 'Cloud data kept changing. Try again.' }
}

async function autoBackup() {
  const { accountKey } = await account.status()
  if (!accountKey) return
  const revText = localStorage.getItem(revisionKey(accountKey))
  if (revText === null) return // First sign-in needs an explicit restore or initial backup.
  const revision = Number(revText)
  if (!Number.isSafeInteger(revision)) return
  const payload = JSON.parse(buildBackup()) as Record<string, unknown>
  const hash = await backupHash(payload)
  if (hash === localStorage.getItem(hashKey(accountKey))) return
  const saved = await account.call('upload', { baseRevision: revision, payload })
  if (saved.status === 200) {
    localStorage.setItem(revisionKey(accountKey), String(saved.data.revision))
    localStorage.setItem(hashKey(accountKey), hash)
  } else if (saved.status === 409) {
    localStorage.removeItem(revisionKey(accountKey))
  }
}

function schedule(delay = 10_000, visible = false) {
  clearTimeout(timer)
  timer = setTimeout(() => sync(visible), delay)
}

onLocalChange(() => schedule())
window.addEventListener('focus', () => schedule(500))
setInterval(() => { if (document.hasFocus() && document.visibilityState === 'visible') schedule(500) }, 60_000)
// Opening the app and asking to refresh are when people look for it, so
// those syncs show the status pill; background syncs stay quiet.
onSyncRequest(() => schedule(0, true))
schedule(1000, true)
