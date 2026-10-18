// Relay connection for a party: AES-256-GCM end-to-end encryption with the
// key from the invite link, relay clock alignment, and reconnect with
// backoff. Uses only WebSocket + WebCrypto, so it runs in the app and in
// Node for the simulation tests.
import type { PartyCore, PartyTransport } from './party'

export const PARTY_RELAY = 'https://vela-party.huzaifah1530.workers.dev'

const b64u = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
const unb64u = (s: string) => {
  const t = s.replace(/-/g, '+').replace(/_/g, '/')
  return Uint8Array.from(atob(t + '='.repeat((4 - (t.length % 4)) % 4)), c => c.charCodeAt(0))
}
const rand = (n: number) => crypto.getRandomValues(new Uint8Array(n))

export interface Invite { room: string; key: string }

export function newInvite(): Invite {
  return { room: b64u(rand(9)), key: b64u(rand(32)) }
}

export function inviteLink(inv: Invite, relay = PARTY_RELAY) {
  return `${relay}/p/${inv.room}#${inv.key}`
}

/** Accepts https://…/p/<room>#<key> or vela://party/<room>#<key>. */
export function parseInvite(text: string): Invite | null {
  const m = /(?:\/p\/|party\/)([A-Za-z0-9_-]{8,32})#([A-Za-z0-9_-]{43})/.exec(text.trim())
  return m ? { room: m[1], key: m[2] } : null
}

export function newIdentity() {
  return { peer: b64u(rand(15)), secret: b64u(rand(24)) }
}

type Status = 'connecting' | 'connected' | 'reconnecting' | 'closed'

export class PartyConnection implements PartyTransport {
  status: Status = 'connecting'
  private ws: WebSocket | null = null
  private key: CryptoKey | null = null
  private offset = 0
  private bestRtt = Infinity
  private retry = 0
  private closedByUser = false
  private timers: ReturnType<typeof setInterval>[] = []
  private outbox: Promise<void> = Promise.resolve()
  private inbox: Promise<void> = Promise.resolve()
  private lastHeard = 0
  private closingSince = 0
  core!: PartyCore
  onStatus?: (s: Status) => void

  constructor(private relay: string, readonly invite: Invite, readonly peer: string, private secret: string) {}

  isOpen() { return this.ws?.readyState === 1 && this.status === 'connected' }

  /** Relay time (ms) estimated from the best round trip seen. */
  now() { return Date.now() + this.offset }

  async open() {
    this.key = await crypto.subtle.importKey('raw', unb64u(this.invite.key), 'AES-GCM', false, ['encrypt', 'decrypt'])
    this.connect()
    this.timers.push(setInterval(() => { if (this.ws?.readyState === 1) this.ws.send('ping') }, 15_000))
    // Watchdog: a dead network often never delivers a close event. If the
    // relay has been silent for 40s (pings are answered every 15s), or the
    // socket is stuck closing, start a fresh connection.
    this.timers.push(setInterval(() => {
      if (this.closedByUser || !this.ws) return
      const stuck = this.ws.readyState === 2 && Date.now() - this.closingSince > 3000
      if (stuck || (this.ws.readyState === 1 && Date.now() - this.lastHeard > 40_000)) this.reconnectNow()
    }, 2000))
    this.timers.push(setInterval(() => this.clockSync(), 30_000))
  }

  close() {
    this.closedByUser = true
    this.timers.forEach(clearInterval)
    try { this.ws?.close(1000, 'bye') } catch { /* ignore */ }
    this.setStatus('closed')
  }

  private setStatus(s: Status) { this.status = s; this.onStatus?.(s) }

  /** Abandon the current socket (if any) and connect again with backoff. */
  reconnectNow() {
    const old = this.ws
    this.ws = null
    try { old?.close(1000, 'reconnect') } catch { /* ignore */ }
    this.core?.disconnected()
    if (this.closedByUser) return
    this.setStatus('reconnecting')
    const delay = Math.min(15_000, 500 * 2 ** this.retry++) * (0.75 + Math.random() * 0.5)
    setTimeout(() => { if (!this.closedByUser && !this.ws) this.connect() }, delay)
  }

  /** Called when the OS reports the network changed (Wi-Fi ↔ cellular). */
  networkChanged() { if (!this.closedByUser) { this.retry = 0; this.reconnectNow() } }

  private connect() {
    const url = this.relay.replace(/^http/, 'ws') + `/room/${this.invite.room}?peer=${this.peer}&s=${this.secret}`
    const ws = new WebSocket(url)
    this.ws = ws
    this.lastHeard = Date.now()
    ws.onopen = () => { this.retry = 0; this.lastHeard = Date.now(); this.clockSync(); setTimeout(() => this.clockSync(), 400) }
    // Decryption is async; chain frames so they're handled in arrival order.
    ws.onmessage = e => { this.lastHeard = Date.now(); const t = String(e.data); this.inbox = this.inbox.then(() => this.onFrame(t)).catch(() => {}) }
    ws.onclose = ev => {
      if (this.ws !== ws) return
      if (ev.code === 4000) { this.ws = null; this.core?.disconnected(); this.setStatus('closed'); return } // replaced by our own newer connection
      // 0.5s, 1s, 2s … capped at 15s, with jitter so a room doesn't stampede.
      this.reconnectNow()
    }
    ws.onerror = () => { /* onclose follows */ }
  }

  private clockSync() {
    if (this.ws?.readyState === 1) this.ws.send(JSON.stringify({ t: 'time', c: Date.now() }))
  }

  private async onFrame(text: string) {
    if (text === 'pong') return
    if ((globalThis as any).process?.env?.PARTY_DEBUG === this.core?.name) console.log(`  [${this.core.name}] frame ${text.slice(0, 90)}`)
    let m: any
    try { m = JSON.parse(text) } catch { return }
    if (m.sys === 'time' && typeof m.echo === 'number') {
      const rtt = Date.now() - m.echo
      // Keep the lowest-latency sample; it's the most accurate.
      if (rtt <= this.bestRtt * 1.5) { this.bestRtt = Math.min(this.bestRtt, rtt); this.offset = m.now - (m.echo + rtt / 2) }
      return
    }
    if (m.sys === 'welcome') {
      this.offset = m.now - Date.now()
      const keep = m.keep ? await this.decrypt(JSON.parse(m.keep).d) : null
      this.setStatus('connected')
      this.core.welcome(m.peers ?? [], keep?.k === 'state' ? keep.s : null, m.now)
      return
    }
    if (m.sys === 'join') { this.core.join(m.peer, m.joined); return }
    if (m.sys === 'leave') { this.core.leave(m.peer); return }
    if (typeof m.from === 'string' && typeof m.d === 'string') {
      const obj = await this.decrypt(m.d)
      if (obj) this.core.receive(m.from, obj)
    }
  }

  private async decrypt(d: string): Promise<any | null> {
    try {
      const raw = unb64u(d)
      const plain = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: raw.slice(0, 12) }, this.key!, raw.slice(12))
      return JSON.parse(new TextDecoder().decode(plain))
    } catch { return null }
  }

  send(obj: unknown, opts: { keep?: boolean; to?: string } = {}) {
    // Keep frames in order even though encryption is async.
    this.outbox = this.outbox.then(async () => {
      if (this.ws?.readyState !== 1 || !this.key) return
      const iv = rand(12)
      const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, this.key, new TextEncoder().encode(JSON.stringify(obj))))
      const blob = new Uint8Array(12 + ct.length); blob.set(iv); blob.set(ct, 12)
      this.ws.send(JSON.stringify({ d: b64u(blob), ...(opts.keep ? { keep: true } : {}), ...(opts.to ? { to: opts.to } : {}) }))
    }).catch(() => {})
  }
}
