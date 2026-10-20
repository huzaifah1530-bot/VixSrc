// Device-link state for the renderer, plus the message handling that only
// the main window performs (commands, playback state, saved-data sync).
import { create } from 'zustand'
import type { LinkEvent, LinkStatus } from '@shared/link'
import { compactIfHuge, shiftDoc, validateDoc } from '@shared/sync'
import { localDoc, mergeRemote, onLocalChange, replaceFromRemote } from '@/lib/sync'
import { publish, runCommandOnce, setConnectedCount } from '@/lib/remote'
import { toast } from './ui'

/** "v1.8.0" and "1.8" both become "1.8.0" so cosmetic differences don't warn. */
const normVersion = (v: string) => {
  const p = v.trim().replace(/^v/i, '').split(/[-+]/)[0].split('.').map(n => parseInt(n, 10) || 0)
  while (p.length < 3) p.push(0)
  return p.join('.')
}

interface Offer { deviceId: string; name: string; doc: ReturnType<typeof validateDoc> }

interface LinkState {
  status: LinkStatus | null
  dialogOpen: boolean
  pairRequestFrom: string | null
  offer: Offer | null
  refresh: () => Promise<void>
  openConnect: (from?: string | null) => Promise<void>
  /** True while the dialog shows the pairing QR rather than the paired list. */
  showQr: boolean
  pairAnother: () => Promise<void>
  closeConnect: () => void
  resolveOffer: (accept: boolean) => void
}

export const useLink = create<LinkState>((set, get) => ({
  status: null,
  dialogOpen: false,
  pairRequestFrom: null,
  offer: null,
  refresh: async () => set({ status: await window.vela.link.status() }),
  showQr: false,
  openConnect: async from => {
    // Already paired: show those devices first; a code is one click away.
    // A phone asking to pair (from) or no pairs yet goes straight to the QR.
    const status = await window.vela.link.status()
    const wantQr = !!from || !status?.devices.length
    set({ dialogOpen: true, pairRequestFrom: from ?? null, status, showQr: wantQr })
    if (wantQr) set({ status: await window.vela.link.startPairing() })
  },
  pairAnother: async () => {
    set({ showQr: true })
    set({ status: await window.vela.link.startPairing() })
  },
  closeConnect: () => { window.vela.link.cancelPairing(); set({ dialogOpen: false, pairRequestFrom: null, showQr: false }) },
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
  window.vela.link.send(deviceId, { t: 'sync-doc', mode, reply, doc: compactIfHuge(localDoc()) })
}

// ── Clock difference to each phone ───────────────────────────────────
// Before merging, find out how far apart the two clocks are, so "newest
// change wins" compares real times. delta = this PC's clock − the phone's.
const clockDelta = new Map<string, number>()
const clockReady = new Map<string, Promise<void>>()
const clockSamples = new Map<string, { rtt: number; delta: number }>()
const CLOCK_PROBES = 5

function measureClock(deviceId: string): Promise<void> {
  clockSamples.delete(deviceId)
  return new Promise(resolve => {
    let sent = 0
    const tick = () => {
      if (sent >= CLOCK_PROBES) return
      sent++
      window.vela.link.send(deviceId, { t: 'clock', c: Date.now() })
      setTimeout(tick, 120)
    }
    tick()
    // Don't hold up syncing for long if the phone doesn't answer (older app).
    setTimeout(() => {
      const best = clockSamples.get(deviceId)
      if (best) {
        clockDelta.set(deviceId, best.delta)
        window.vela.link.send(deviceId, { t: 'clock-offset', d: best.delta })
      }
      resolve()
    }, CLOCK_PROBES * 120 + 700)
  })
}

function onClockReply(deviceId: string, m: Record<string, unknown>) {
  if (typeof m.c !== 'number' || typeof m.s !== 'number') return
  const rtt = Date.now() - m.c
  if (rtt < 0 || rtt > 5000) return
  const delta = m.c + rtt / 2 - m.s
  const best = clockSamples.get(deviceId)
  if (!best || rtt < best.rtt) clockSamples.set(deviceId, { rtt, delta })
}

/** A document from a phone, with its timestamps converted to this PC's clock. */
const fromPhone = (deviceId: string, doc: NonNullable<ReturnType<typeof validateDoc>>) => shiftDoc(doc, clockDelta.get(deviceId) ?? 0)

async function onMessage(deviceId: string, m: Record<string, unknown>) {
  switch (m.t) {
    case 'clock-reply':
      onClockReply(deviceId, m)
      return
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
      await clockReady.get(deviceId) // know the clock difference first
      const valid = validateDoc(m.doc)
      const doc = valid && fromPhone(deviceId, valid)
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
      const valid = validateDoc(m.doc)
      const doc = valid && fromPhone(deviceId, valid)
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
        if (e.status.pairing && (!useLink.getState().dialogOpen || !useLink.getState().showQr)) useLink.setState({ dialogOpen: true, showQr: true })
        break
      }
      case 'pair-request': useLink.getState().openConnect(e.name); break
      case 'paired': useLink.setState({ dialogOpen: false, pairRequestFrom: null }); toast(`Paired with ${e.name}`); break
      case 'connected':
        if (e.appVersion !== undefined && normVersion(e.appVersion ?? '') !== normVersion(window.vela.version)) {
          toast(`${e.name ?? 'Your iPhone'} is on ${e.appVersion ? 'Vela ' + e.appVersion : 'an older version of Vela'} and this PC is on ${window.vela.version}. Some features may not work properly.`, 6000)
        }
        publish(e.deviceId)
        {
          const id = e.deviceId
          const ready = measureClock(id)
          clockReady.set(id, ready)
          ready.then(() => { if (device(id)?.syncEnabled) sendDoc(id, 'merge', true) })
        }
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
