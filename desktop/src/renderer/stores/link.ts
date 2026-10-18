// Device-link state for the renderer, plus the message handling that only
// the main window performs (commands, playback state, saved-data sync).
import { create } from 'zustand'
import type { LinkEvent, LinkStatus } from '@shared/link'
import { validateDoc } from '@shared/sync'
import { localDoc, mergeRemote, onLocalChange, replaceFromRemote } from '@/lib/sync'
import { publish, runCommandOnce, setConnectedCount } from '@/lib/remote'
import { toast } from './ui'

interface Offer { deviceId: string; name: string; doc: ReturnType<typeof validateDoc> }

interface LinkState {
  status: LinkStatus | null
  dialogOpen: boolean
  pairRequestFrom: string | null
  offer: Offer | null
  refresh: () => Promise<void>
  openConnect: (from?: string | null) => Promise<void>
  closeConnect: () => void
  resolveOffer: (accept: boolean) => void
}

export const useLink = create<LinkState>((set, get) => ({
  status: null,
  dialogOpen: false,
  pairRequestFrom: null,
  offer: null,
  refresh: async () => set({ status: await window.vela.link.status() }),
  openConnect: async from => {
    set({ dialogOpen: true, pairRequestFrom: from ?? null })
    set({ status: await window.vela.link.startPairing() })
  },
  closeConnect: () => { window.vela.link.cancelPairing(); set({ dialogOpen: false, pairRequestFrom: null }) },
  resolveOffer: accept => {
    const offer = get().offer
    set({ offer: null })
    if (!offer) return
    if (accept && offer.doc) {
      replaceFromRemote(offer.doc)
      window.vela.link.update(offer.deviceId, { syncEnabled: true, lastSync: Date.now() })
      toast(`This PC now matches ${offer.name}`)
    }
    window.vela.link.send(offer.deviceId, { t: 'fresh-copy-result', ok: accept && !!offer.doc })
  }
}))

const device = (id: string) => useLink.getState().status?.devices.find(d => d.deviceId === id)
const pendingReplace = new Map<string, number>()

function sendDoc(deviceId: string, mode: 'merge' | 'replace', reply: boolean) {
  window.vela.link.send(deviceId, { t: 'sync-doc', mode, reply, doc: localDoc() })
}

async function onMessage(deviceId: string, m: Record<string, unknown>) {
  switch (m.t) {
    case 'cmd': {
      // Two replies: "got" as soon as it arrives, then "ack" once the player
      // has actually done it (or failed), so the phone can tell lost
      // messages from commands that didn't take effect.
      window.vela.link.send(deviceId, { t: 'got', id: m.id })
      const error = await runCommandOnce(m)
      window.vela.link.send(deviceId, { t: 'ack', id: m.id, ok: !error, error })
      publish(deviceId)
      return
    }
    case 'state-request':
      publish(deviceId)
      return
    case 'sync-doc': {
      const doc = validateDoc(m.doc)
      if (!doc) { toast('Ignored an invalid sync from ' + (device(deviceId)?.name ?? 'phone')); return }
      if (m.mode === 'replace') {
        const until = pendingReplace.get(deviceId)
        pendingReplace.delete(deviceId)
        if (!until || until < Date.now()) return // we never asked for this
        replaceFromRemote(doc)
        window.vela.link.update(deviceId, { syncEnabled: true, lastSync: Date.now() })
        toast(`Copied from ${device(deviceId)?.name ?? 'your phone'}`)
        sendDoc(deviceId, 'merge', false)
        return
      }
      // The phone may have switched sync on a moment ago; ask main if unsure.
      if (!device(deviceId)?.syncEnabled) await useLink.getState().refresh()
      if (!device(deviceId)?.syncEnabled) return
      mergeRemote(doc)
      window.vela.link.update(deviceId, { lastSync: Date.now() })
      if (m.reply === true) sendDoc(deviceId, 'merge', false)
      return
    }
    case 'sync-request':
      // The phone is about to become a copy of this PC (it confirmed first).
      if (m.mode === 'replace') sendDoc(deviceId, 'replace', false)
      return
    case 'fresh-copy-offer': {
      const doc = validateDoc(m.doc)
      useLink.setState({ offer: { deviceId, name: device(deviceId)?.name ?? 'your phone', doc } })
      window.vela.showMainWindow()
      return
    }
    case 'fresh-copy-result':
      if (m.ok === true) { window.vela.link.update(deviceId, { syncEnabled: true, lastSync: Date.now() }); toast(`${device(deviceId)?.name ?? 'Phone'} now matches this PC`) }
      else toast('Copy was cancelled on the phone')
      return
  }
}

/** Main window only: wires link events to commands, state and sync. */
export function startLinkClient() {
  useLink.getState().refresh()
  let lastLive = 0
  const off = window.vela.on('link', (e: LinkEvent) => {
    switch (e.type) {
      case 'status': {
        useLink.setState({ status: e.status })
        const live = e.status.devices.filter(d => d.connected).length
        if (live !== lastLive) { lastLive = live; setConnectedCount(live) }
        // Pairing started from the Settings window shows the code here.
        if (e.status.pairing && !useLink.getState().dialogOpen) useLink.setState({ dialogOpen: true })
        break
      }
      case 'pair-request': useLink.getState().openConnect(e.name); break
      case 'paired': useLink.setState({ dialogOpen: false, pairRequestFrom: null }); toast(`Paired with ${e.name}`); break
      case 'connected':
        publish(e.deviceId)
        setTimeout(() => { if (device(e.deviceId)?.syncEnabled) sendDoc(e.deviceId, 'merge', true) }, 300)
        break
      case 'message': onMessage(e.deviceId, e.msg); break
      case 'action':
        if (e.action === 'sync-now') sendDoc(e.deviceId, 'merge', true)
        else if (e.action === 'fresh-copy-to') window.vela.link.send(e.deviceId, { t: 'fresh-copy-offer', doc: localDoc() })
        else if (e.action === 'fresh-copy-from') {
          pendingReplace.set(e.deviceId, Date.now() + 60_000)
          window.vela.link.send(e.deviceId, { t: 'sync-request', mode: 'replace' })
        }
        break
    }
  })
  // Push saved changes to every connected phone that has sync on.
  const offLocal = onLocalChange(() => {
    for (const d of useLink.getState().status?.devices ?? []) if (d.connected && d.syncEnabled) sendDoc(d.deviceId, 'merge', false)
  })
  return () => { off(); offLocal() }
}

/** Settings window: status only. */
export function startLinkStatus() {
  useLink.getState().refresh()
  return window.vela.on('link', e => { if (e.type === 'status') useLink.setState({ status: e.status }) })
}
