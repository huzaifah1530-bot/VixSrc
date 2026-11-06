import type { AccountApi } from '@shared/account'
import { validateDoc } from '@shared/sync'
import { localDoc, mergeRemote, onLocalChange } from './sync'
import { buildBackup } from './backup'
import { backupHash, hashKey, revisionKey } from './accountBackup'

const account = (window.vela as typeof window.vela & { account: AccountApi }).account
let timer: ReturnType<typeof setTimeout> | undefined
let busy = false
let pending = false

async function sync() {
  if (busy) { pending = true; return }
  busy = true
  try {
    if (!(await account.status()).username) return
    for (let attempt = 0; attempt < 3; attempt++) {
      const incoming = await account.call('downloadShared')
      if (incoming.status !== 200 && incoming.status !== 404) return
      const revision = incoming.status === 200 ? incoming.data.revision : 0
      const remote = incoming.status === 200 ? validateDoc(incoming.data.payload) : null
      if (incoming.status === 200 && !remote) return
      if (remote) mergeRemote(remote)
      const saved = await account.call('uploadShared', { baseRevision: revision, payload: localDoc() })
      if (saved.status === 200) { await autoBackup(); return }
      if (saved.status !== 409) return
    }
  } catch { /* Offline is normal; the next local edit or foreground poll retries. */ }
  finally {
    busy = false
    if (pending) { pending = false; schedule(1000) }
  }
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

function schedule(delay = 10_000) {
  clearTimeout(timer)
  timer = setTimeout(sync, delay)
}

onLocalChange(() => schedule())
window.addEventListener('focus', () => schedule(500))
setInterval(() => { if (document.hasFocus() && document.visibilityState === 'visible') schedule(500) }, 60_000)
schedule(1000)
