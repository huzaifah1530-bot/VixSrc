import type { AccountApi } from '@shared/account'
import { validateDoc } from '@shared/sync'
import { localDoc, mergeRemote, onLocalChange } from './sync'

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
      if (saved.status === 200) return
      if (saved.status !== 409) return
    }
  } catch { /* Offline is normal; the next local edit or foreground poll retries. */ }
  finally {
    busy = false
    if (pending) { pending = false; schedule(1000) }
  }
}

function schedule(delay = 10_000) {
  clearTimeout(timer)
  timer = setTimeout(sync, delay)
}

onLocalChange(() => schedule())
window.addEventListener('focus', () => schedule(500))
setInterval(() => schedule(500), 60_000)
schedule(1000)
