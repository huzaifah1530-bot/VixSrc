// Watch Together sync core. No DOM, no network: the app supplies a
// transport and a player, which also lets scripts/party-sim.ts run many
// simulated viewers. Swift twin: ios/.../Services/Party/PartyCore.swift.
//
// Model
//  • The room has one shared Timeline: what's playing, playing/paused, and
//    the position at a moment on the relay's clock. Anyone's "now" position
//    is computed from it, so nobody has to stream time to anyone.
//  • Changes are versioned (n, by). Higher n wins; ties break on peer id, so
//    two people pausing at once settle on the same result everywhere.
//  • Every viewer keeps its own player on the timeline: small drift is
//    eased out with playback speed, large drift jumps.
//  • Captions, Sub/Dub, quality, volume and a personal offset never leave
//    the device.
//
// Scenarios handled (see PARTY.md in the PR notes / tests):
//  - Viewer falls behind (slow network): speed nudge, then jump; after
//    repeated jumps the app is told to step quality down.
//  - Viewer stalls: if the host enabled "wait for everyone", the room holds
//    until they recover, but only for up to WAIT_LIMIT_MS — then the room
//    carries on and they catch up alone, so one bad connection can't freeze
//    a big room. Waiting is also capped to the first WAIT_MAX_PEERS stalls.
//  - Host disconnects: the timeline keeps running from the last state (it
//    lives in the relay). Host duties pass to the longest-present viewer;
//    if control was host-only, that viewer gets it. The original host gets
//    everything back when they return (same peer id + secret).
//  - Everyone's own connection drops: playback continues locally along
//    the last timeline; controls are disabled; on reconnect the room's
//    current timeline wins (no stale actions are replayed).
//  - Late join / rejoin: the relay hands over the latest state instantly.
//  - Episode end: only the leader advances, once; others follow.
//  - Two controllers act together: version tie-break, everyone converges.
//  - Permissions: enforced by every receiver, not just the sender's UI.
//    Sender ids come from the relay and can't be forged (peer secrets).

export const PARTY_VERSION = 1
export const WAIT_LIMIT_MS = 15_000
export const WAIT_MAX_PEERS = 8
export const HARD_SYNC_S = 2
export const SOFT_SYNC_S = 0.25
export const HOST_CHECK_MS = 1000

export type PartyMedia =
  | { kind: 'tmdb'; key: string; item: Record<string, unknown>; season: number | null; episode: number | null; episodeTitle?: string | null; server: string }
  | { kind: 'anime'; key: string; item: Record<string, unknown>; slug: string; episode: string; title: string; server: string }

export interface Timeline {
  n: number
  by: string
  media: PartyMedia | null
  playing: boolean
  /** seconds at `at` */
  pos: number
  /** relay clock ms */
  at: number
  /** paused by "wait for everyone" (resumes by itself), not by a person */
  hold: boolean
}

export type ControlMode = 'everyone' | 'host' | 'select'

export interface PartyConfig {
  n: number
  host: string
  mode: ControlMode
  allowed: string[]
  waitForAll: boolean
}

export interface RoomState { v: number; tl: Timeline; cfg: PartyConfig }

export interface Peer { id: string; name: string; platform: string; joined: number; buffering: boolean; bufSince: number; error: string | null; lastSeen: number }

/** A peer silent this long is treated as gone even if its socket lingers. */
export const PEER_TIMEOUT_MS = 75_000
export const ALIVE_EVERY_MS = 30_000

export interface PartyTransport {
  send(obj: unknown, opts?: { keep?: boolean; to?: string }): void
  /** False the moment the socket is closing, before any close event. */
  isOpen(): boolean
  /** relay clock in ms */
  now(): number
}

export interface PartyEvents {
  /** The room switched to something this device isn't playing. */
  onMedia?(media: PartyMedia | null, tl: Timeline): void
  onChange?(): void
  onToast?(msg: string): void
  /** Repeated hard re-syncs: suggest/perform a quality step down. */
  onStruggling?(): void
  /** Leader reached the end of an episode: return the next media, or null. */
  nextMedia?(current: PartyMedia): Promise<PartyMedia | null> | PartyMedia | null
}

export function newer(a: { n: number; by: string }, b: { n: number; by: string }) {
  return a.n !== b.n ? a.n > b.n : a.by > b.by
}

export function positionAt(tl: Timeline, now: number) {
  return tl.playing ? tl.pos + Math.max(0, now - tl.at) / 1000 : tl.pos
}

/** What a local player should do to stay on the timeline. */
export function correction(local: { pos: number; playing: boolean }, target: { pos: number; playing: boolean }) {
  const drift = local.pos - target.pos
  if (!target.playing) {
    return { play: false, rate: 1, seek: Math.abs(drift) > 0.5 ? target.pos : null, drift }
  }
  if (Math.abs(drift) > HARD_SYNC_S) return { play: true, rate: 1, seek: target.pos + 0.25, drift }
  const a = Math.abs(drift)
  const rate = a < SOFT_SYNC_S ? 1 : drift > 0 ? (a > 1 ? 0.9 : 0.95) : (a > 1 ? 1.1 : 1.05)
  return { play: true, rate, seek: null, drift }
}

const str = (v: unknown, max = 500) => typeof v === 'string' && v.length <= max
const num = (v: unknown) => typeof v === 'number' && Number.isFinite(v)

function validMedia(m: any): m is PartyMedia {
  if (m === null) return true
  if (!m || typeof m !== 'object' || !str(m.key, 300) || !m.item || typeof m.item !== 'object' || !str(m.server, 120)) return false
  if (m.kind === 'tmdb') return (m.season === null || Number.isInteger(m.season)) && (m.episode === null || Number.isInteger(m.episode))
  if (m.kind === 'anime') return str(m.slug, 200) && str(m.episode, 12) && str(m.title, 500)
  return false
}
function validTimeline(t: any): t is Timeline {
  return t && Number.isInteger(t.n) && str(t.by, 40) && validMedia(t.media) && typeof t.playing === 'boolean' &&
    num(t.pos) && t.pos >= 0 && t.pos < 1e6 && num(t.at) && typeof t.hold === 'boolean'
}
function validConfig(c: any): c is PartyConfig {
  return c && Number.isInteger(c.n) && str(c.host, 40) && ['everyone', 'host', 'select'].includes(c.mode) &&
    Array.isArray(c.allowed) && c.allowed.length <= 500 && c.allowed.every((x: unknown) => str(x, 40)) && typeof c.waitForAll === 'boolean'
}

export class PartyCore {
  state: RoomState | null = null
  peers = new Map<string, Peer>()
  connected = false
  private excluded = new Set<string>()
  private myBuffering = false
  private hardSyncs: number[] = []
  private advancing = false
  private lastSentTl = 0

  constructor(
    readonly me: string,
    readonly name: string,
    readonly platform: string,
    private transport: PartyTransport,
    private events: PartyEvents = {}
  ) {}

  // ── Roles ────────────────────────────────────────────────────────────
  private present(id: string) {
    if (id === this.me) return true
    const p = this.peers.get(id)
    return !!p && Date.now() - p.lastSeen < PEER_TIMEOUT_MS
  }

  /** The configured host if they're here, else whoever's been here longest. */
  get leader(): string {
    const cfg = this.state?.cfg
    if (cfg && this.present(cfg.host)) return cfg.host
    const all = [...[...this.peers.values()].filter(p => this.present(p.id)), { id: this.me, joined: this.joinedAt }]
    return all.sort((a, b) => a.joined - b.joined || (a.id < b.id ? -1 : 1))[0].id
  }
  joinedAt = Number.MAX_SAFE_INTEGER

  get isLeader() { return this.leader === this.me }
  get isHost() { return this.state?.cfg.host === this.me }

  canControl(id = this.me): boolean {
    const cfg = this.state?.cfg
    if (!cfg) return true
    if (id === this.leader) return true
    if (cfg.mode === 'everyone') return true
    if (cfg.mode === 'select') return cfg.allowed.includes(id)
    return false
  }

  /** Only the configured host (or acting leader while they're away) changes settings. */
  canConfigure(id = this.me) { return id === this.leader }

  // ── Transport events ─────────────────────────────────────────────────
  /** Room creator: start a fresh room with this media. */
  create(media: PartyMedia | null, pos: number, playing: boolean) {
    const now = this.transport.now()
    this.state = {
      v: PARTY_VERSION,
      tl: { n: 1, by: this.me, media, playing, pos, at: now, hold: false },
      cfg: { n: 1, host: this.me, mode: 'everyone', allowed: [], waitForAll: true }
    }
    this.publishState()
  }

  welcome(peers: { peer: string; joined: number }[], keep: unknown, myJoined: number) {
    this.connected = true
    this.joinedAt = myJoined
    this.peers.clear()
    for (const p of peers) this.peers.set(p.peer, { id: p.peer, name: '…', platform: '', joined: p.joined, buffering: false, bufSince: 0, error: null, lastSeen: Date.now() })
    this.transport.send({ k: 'hello', name: this.name, platform: this.platform, buffering: this.myBuffering })
    const incoming = this.parseState(keep)
    // Reconnect: the room's current state wins over whatever we had.
    if (incoming) this.adopt(incoming, true)
    else if (this.state && this.isLeader) this.publishState() // we're alone again; re-seed the relay
    this.events.onChange?.()
  }

  disconnected() {
    this.connected = false
    this.events.onChange?.()
  }

  join(peer: string, joined: number) {
    this.peers.set(peer, { id: peer, name: '…', platform: '', joined, buffering: false, bufSince: 0, error: null, lastSeen: Date.now() })
    this.transport.send({ k: 'hello', name: this.name, platform: this.platform, buffering: this.myBuffering }, { to: peer })
    this.events.onChange?.()
  }

  leave(peer: string) {
    const was = this.peers.get(peer)
    this.peers.delete(peer)
    this.excluded.delete(peer)
    if (was && this.state?.cfg.host === peer) this.events.onToast?.(`${was.name} (host) left — ${this.peers.get(this.leader)?.name ?? 'you'} ${this.isLeader ? 'are' : 'is'} in charge until they're back`)
    else if (was) this.events.onToast?.(`${was.name} left`)
    this.events.onChange?.()
  }

  receive(from: string, raw: unknown) {
    const m = raw as Record<string, unknown> | null
    if (!m || typeof m !== 'object' || typeof m.k !== 'string') return
    const peer = this.peers.get(from)
    if (peer) peer.lastSeen = Date.now()
    switch (m.k) {
      case 'alive': return
      case 'hello':
        if (peer) {
          peer.name = str(m.name, 60) ? (m.name as string) : 'Guest'
          peer.platform = str(m.platform, 20) ? (m.platform as string) : ''
          peer.buffering = m.buffering === true
          peer.bufSince = peer.buffering ? Date.now() : 0
          this.events.onChange?.()
        }
        return
      case 'state': {
        const s = this.parseState(m.s)
        if (!s) return
        // The timeline part only counts if its author may control; the
        // config part only if its author may configure.
        const tlOk = s.tl.by === from && this.canControlUnder(from, this.state?.cfg ?? s.cfg)
        const cfgOk = !this.state || (s.cfg.n === this.state.cfg.n && JSON.stringify(s.cfg) === JSON.stringify(this.state.cfg)) || this.canConfigure(from)
        if (!cfgOk) s.cfg = this.state!.cfg
        if (!tlOk && this.state) s.tl = this.state.tl
        this.adopt(s, false)
        return
      }
      case 'buf':
        if (peer) {
          const on = m.on === true
          if (on !== peer.buffering) { peer.buffering = on; peer.bufSince = on ? Date.now() : 0; if (!on) this.excluded.delete(from) }
          peer.error = str(m.error, 200) ? (m.error as string) : null
          this.events.onChange?.()
        }
        return
      case 'req-sync':
        // Someone asks for the latest state directly (e.g. after a gap).
        if (this.state && this.isLeader) this.transport.send({ k: 'state', s: this.state }, { to: from })
        return
    }
  }

  private canControlUnder(id: string, cfg: PartyConfig) {
    if (id === this.leader) return true
    return cfg.mode === 'everyone' || (cfg.mode === 'select' && cfg.allowed.includes(id))
  }

  private parseState(raw: unknown): RoomState | null {
    const s = raw as RoomState | null
    if (!s || s.v !== PARTY_VERSION || !validTimeline(s.tl) || !validConfig(s.cfg)) return null
    return { v: s.v, tl: { ...s.tl }, cfg: { ...s.cfg, allowed: [...s.cfg.allowed] } }
  }

  private adopt(s: RoomState, force: boolean) {
    const prev = this.state
    if ((globalThis as any).process?.env?.PARTY_DEBUG === this.name) console.log(`  [${this.name}] adopt force=${force} incoming n=${s.tl.n} by=${s.tl.by.slice(0, 4)} pos=${s.tl.pos.toFixed(0)} prev n=${prev?.tl.n}`)
    let tl = prev?.tl, cfg = prev?.cfg
    if (!prev || force || newer(s.tl, prev.tl)) tl = s.tl
    if (!prev || force || s.cfg.n > prev.cfg.n) cfg = s.cfg
    const mediaChanged = (prev?.tl.media?.key ?? null) !== (tl!.media?.key ?? null)
    this.state = { v: PARTY_VERSION, tl: tl!, cfg: cfg! }
    if (mediaChanged || force) this.events.onMedia?.(tl!.media, tl!)
    this.events.onChange?.()
  }

  private publishState() {
    if (!this.state) return
    this.lastSentTl = Date.now()
    this.transport.send({ k: 'state', s: this.state }, { keep: true })
    this.events.onChange?.()
  }

  // ── Local user actions (return false when not allowed) ──────────────
  private bump(change: Partial<Timeline>): boolean {
    if (!this.state || !this.connected || !this.transport.isOpen()) { this.events.onToast?.('Reconnecting to the party…'); return false }
    if (!this.canControl()) { this.events.onToast?.('The host is controlling playback'); return false }
    const now = this.transport.now()
    const cur = this.state.tl
    this.state = {
      ...this.state,
      tl: { ...cur, pos: positionAt(cur, now), at: now, hold: false, ...change, n: cur.n + 1, by: this.me }
    }
    this.publishState()
    return true
  }

  play() { return this.bump({ playing: true }) }
  pause() { return this.bump({ playing: false }) }
  seek(pos: number) { return this.bump({ pos: Math.max(0, pos) }) }
  skip(by: number) { return this.state ? this.seek(this.target().pos + by) : false }
  setMedia(media: PartyMedia | null) {
    const ok = this.bump({ media, pos: 0, playing: true })
    if (ok) this.events.onMedia?.(media, this.state!.tl)
    return ok
  }

  configure(patch: Partial<Omit<PartyConfig, 'n' | 'host'>>) {
    if (!this.state || !this.canConfigure()) return false
    this.state = { ...this.state, cfg: { ...this.state.cfg, ...patch, n: this.state.cfg.n + 1 } }
    this.publishState()
    return true
  }

  // ── Local player reports ─────────────────────────────────────────────
  target(): { media: PartyMedia | null; playing: boolean; pos: number } {
    const tl = this.state?.tl
    if (!tl) return { media: null, playing: false, pos: 0 }
    return { media: tl.media, playing: tl.playing, pos: positionAt(tl, this.transport.now()) }
  }

  /** Call from the player loop with this device's position (after the personal offset). */
  sync(local: { pos: number; playing: boolean }) {
    const t = this.target()
    const c = correction(local, t)
    if (c.seek !== null && t.playing) {
      const now = Date.now()
      this.hardSyncs = [...this.hardSyncs.filter(x => now - x < 30_000), now]
      if (this.hardSyncs.length >= 3) { this.hardSyncs = []; this.events.onStruggling?.() }
    }
    return c
  }

  setBuffering(on: boolean, error: string | null = null) {
    if (on === this.myBuffering && !error) return
    this.myBuffering = on
    if (this.connected) this.transport.send({ k: 'buf', on, error })
  }

  /** Local player reached the end of the current media. */
  async ended() {
    if (!this.state || !this.isLeader || this.advancing) return
    const media = this.state.tl.media
    if (!media) return
    this.advancing = true
    try {
      const next = await this.events.nextMedia?.(media)
      // Someone may have changed things while we looked it up.
      if (this.state.tl.media?.key !== media.key) return
      if (next) this.setMedia(next)
      else this.pause()
    } finally { this.advancing = false }
  }

  // ── Leader duties, call about once a second ─────────────────────────
  private lastAlive = 0

  tick() {
    // Everyone: a tiny "still here" every 30s, so a viewer whose network died
    // without closing is noticed (PEER_TIMEOUT_MS) and can't hold the room.
    if (this.connected && Date.now() - this.lastAlive > ALIVE_EVERY_MS) {
      this.lastAlive = Date.now()
      this.transport.send({ k: 'alive' })
    }
    if (!this.state || !this.connected || !this.isLeader) return
    const { tl, cfg } = this.state
    const now = Date.now()
    // Who's holding the room up (stalled, not yet given up on)?
    const stalled = [...this.peers.values()]
      .filter(p => p.buffering && !this.excluded.has(p.id) && this.present(p.id))
      .sort((a, b) => a.bufSince - b.bufSince)
    for (const p of stalled) {
      if (now - p.bufSince > WAIT_LIMIT_MS) {
        this.excluded.add(p.id)
        this.events.onToast?.(`Carrying on without ${p.name} — they'll catch up`)
      }
    }
    const waitingOn = stalled.filter(p => !this.excluded.has(p.id)).slice(0, WAIT_MAX_PEERS)
    const meStalled = this.myBuffering
    if (cfg.waitForAll && tl.playing && (waitingOn.length || meStalled) && tl.media) {
      this.bumpAsLeader({ playing: false, hold: true })
    } else if (tl.hold && !tl.playing && !waitingOn.length && !meStalled) {
      this.bumpAsLeader({ playing: true, hold: false })
    } else if (now - this.lastSentTl > 30_000) {
      // Refresh the relay's copy now and then (cheap, one message).
      this.publishState()
    }
  }

  private bumpAsLeader(change: Partial<Timeline>) {
    const now = this.transport.now()
    const cur = this.state!.tl
    this.state = { ...this.state!, tl: { ...cur, pos: positionAt(cur, now), at: now, ...change, n: cur.n + 1, by: this.me } }
    this.publishState()
  }

  waitingOn(): Peer[] {
    if (!this.state?.tl.hold) return []
    return [...this.peers.values()].filter(p => p.buffering && !this.excluded.has(p.id))
  }
}
