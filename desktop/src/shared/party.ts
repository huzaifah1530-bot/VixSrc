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
/**
 * Off by more than this and a player jumps. Under it, playback speed eases
 * the gap out smoothly. Players that can't change speed (web players) use the
 * smaller coarse limit instead, since a jump is their only tool.
 */
export const HARD_SYNC_S = 5
export const HARD_SYNC_COARSE_S = 2
/** Every PROBE_EVERY_MS the leader asks everyone where they are at one agreed moment. */
export const PROBE_EVERY_MS = 30_000
export const PROBE_LEAD_MS = 10_000
export const PROBE_COLLECT_MS = 4_000
/** The leader's own player differing from the timeline by more than this moves the timeline to it. */
export const REANCHOR_S = 0.3
export const SOFT_SYNC_S = 0.25
export const HOST_CHECK_MS = 1000
export const STALL_WINDOW_MS = 1500
export const STALL_GRACE_MS = 2500
export const HARD_SEEK_COOLDOWN_MS = 4000
/** Don't hold the room again for this long after it resumes. */
export const REHOLD_COOLDOWN_MS = 3000

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

export interface Peer { id: string; name: string; platform: string; joined: number; buffering: boolean; bufSince: number; error: string | null; lastSeen: number; /** seconds ahead (+) or behind (-) the leader at the last check */ gap: number | null }

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
  /**
   * The room's media changed. `initial` = first state after joining /
   * reconnecting; `mine` = this device made the change.
   */
  onMedia?(media: PartyMedia | null, tl: Timeline, info: { initial: boolean; mine: boolean }): void
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
export function correction(local: { pos: number; playing: boolean }, target: { pos: number; playing: boolean }, canNudge = true) {
  const drift = local.pos - target.pos
  if (!target.playing) {
    return { play: false, rate: 1, seek: Math.abs(drift) > 0.5 ? target.pos : null, drift }
  }
  if (Math.abs(drift) > (canNudge ? HARD_SYNC_S : HARD_SYNC_COARSE_S)) return { play: true, rate: 1, seek: target.pos + 0.25, drift }
  if (!canNudge) return { play: true, rate: 1, seek: null, drift }
  // Smooth catch-up: the bigger the gap, the stronger the nudge (5 / 10 / 15 %).
  const a = Math.abs(drift)
  const step = a < SOFT_SYNC_S ? 0 : a < 1 ? 0.05 : a < 2.5 ? 0.1 : 0.15
  const rate = 1 + (drift > 0 ? -step : step)
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
    for (const p of peers) this.peers.set(p.peer, { id: p.peer, name: '…', platform: '', joined: p.joined, buffering: false, bufSince: 0, error: null, lastSeen: Date.now(), gap: null })
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
    this.peers.set(peer, { id: peer, name: '…', platform: '', joined, buffering: false, bufSince: 0, error: null, lastSeen: Date.now(), gap: null })
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
        const mediaChange = !!this.state && (this.state.tl.media?.key ?? null) !== (s.tl.media?.key ?? null)
        const tlOk = s.tl.by === from && this.canControlUnder(from, this.state?.cfg ?? s.cfg) && (!mediaChange || from === this.leader)
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
      case 'probe': {
        if (from !== this.leader || from === this.me || !Number.isInteger(m.id) || !num(m.at)) return
        const tn = this.transport.now()
        if ((m.at as number) < tn - 1000 || (m.at as number) > tn + 30_000) return
        this.probe = { id: m.id as number, at: m.at as number, from, answered: false, replies: new Map(), n: -1 }
        return
      }
      case 'probe-reply': {
        const p = this.probe
        if (!p || p.from !== this.me || m.id !== p.id || !num(m.pos) || (m.pos as number) < 0 || (m.pos as number) >= 1e6) return
        if (peer) p.replies.set(from, m.pos as number)
        return
      }
      case 'probe-result': {
        if (from !== this.leader || !m.gaps || typeof m.gaps !== 'object') return
        for (const [id, g] of Object.entries(m.gaps as Record<string, unknown>).slice(0, 200)) {
          if (!num(g)) continue
          if (id === this.me) this.myGap = g as number
          else { const q = this.peers.get(id); if (q) q.gap = g as number }
        }
        const lead = this.peers.get(from)
        if (lead) lead.gap = 0
        this.events.onChange?.()
        return
      }
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
    let tl = prev?.tl, cfg = prev?.cfg
    if (!prev || force || newer(s.tl, prev.tl)) tl = s.tl
    if (!prev || force || s.cfg.n > prev.cfg.n) cfg = s.cfg
    const mediaChanged = (prev?.tl.media?.key ?? null) !== (tl!.media?.key ?? null)
    this.state = { v: PARTY_VERSION, tl: tl!, cfg: cfg! }
    if (mediaChanged) { this.resetProgress(Date.now()); this.stalled = false }
    if (mediaChanged || force) this.events.onMedia?.(tl!.media, tl!, { initial: force || !prev, mine: tl!.by === this.me })
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
      // A seek during a "waiting for…" hold keeps the hold, so the room
      // still resumes by itself; an explicit play / pause ends it.
      tl: { ...cur, pos: positionAt(cur, now), at: now, hold: change.playing === undefined && change.media === undefined ? cur.hold : false, ...change, n: cur.n + 1, by: this.me }
    }
    this.publishState()
    return true
  }

  play() { return this.bump({ playing: true }) }
  pause() { return this.bump({ playing: false }) }
  seek(pos: number) { return this.bump({ pos: Math.max(0, pos) }) }
  skip(by: number) { return this.state ? this.seek(this.target().pos + by) : false }
  /** Only the host (or acting host) picks what the room watches. `null` = browsing. */
  setMedia(media: PartyMedia | null, startAt = 0) {
    if (!this.isLeader) { this.events.onToast?.('Only the host can change what’s playing'); return false }
    const ok = this.bump({ media, pos: Math.max(0, startAt), playing: media !== null })
    if (ok) this.events.onMedia?.(media, this.state!.tl, { initial: false, mine: true })
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

  // ── Stall detection ──────────────────────────────────────────────────
  // "Buffering" means: the room wants this player to play, and its position
  // has barely moved for STALL_WINDOW_MS (after a grace period). It's
  // measured from real progress, not the player's own "waiting" flag, which
  // flickers on seeks and speed changes. That flicker used to make a host
  // hold the room for themselves, pause, "recover", resume and stall again
  // — the freezing loop.
  private samples: { t: number; pos: number }[] = []
  private wantSince = 0
  private stalled = false
  private loading = false
  private lastHardSeek = 0
  private lastHardSeekN = -1
  private loadingError: string | null = null

  /**
   * Call from the player loop with this device's position (after the
   * personal offset). `quiet` = a personal reload (Sub/Dub, quality) is in
   * progress: never hold the room for it.
   */
  sync(local: { pos: number; playing: boolean; ended?: boolean }, quiet = false, canNudge = true) {
    const now = Date.now()
    const t = this.target()
    this.answerProbe(local)
    const holdingForMe = !!this.state?.tl.hold && this.stalled
    // At the end of the video "not moving" is expected, not a stall.
    const want = (t.playing || holdingForMe) && !local.ended
    // Sitting at the end while the room still plays: the host moves it on
    // (retried every tick, so a missed "ended" event can't strand the room).
    if (local.ended && t.playing && this.isLeader) void this.ended()

    this.samples = [...this.samples.filter(s => now - s.t < 2500), { t: now, pos: local.pos }]
    let notMoving = false
    if (!want || quiet) {
      this.stalled = false
      this.wantSince = 0
    } else {
      if (!this.wantSince) this.wantSince = now
      // Position jumped back (new episode, local reload): restart measuring
      // rather than reading it as "not moving".
      const prevSample = this.samples[this.samples.length - 2]
      if (prevSample && local.pos < prevSample.pos - 1) this.resetProgress(now)
      const old = this.samples.find(s => now - s.t >= STALL_WINDOW_MS)
      if (old) {
        const moved = local.pos - old.pos
        notMoving = moved < 0.3
        if (notMoving && now - this.wantSince > STALL_GRACE_MS) this.stalled = true
        else if (moved > 0.8) this.stalled = false
      }
    }
    this.publishBuffering()

    // The room is waiting for us: keep trying to play where it stopped
    // (pausing here would hide whether we've recovered).
    if (holdingForMe) {
      const seek = Math.abs(local.pos - t.pos) > 3 ? t.pos : null
      if (seek !== null) this.resetProgress(now)
      return { play: true, rate: 1, seek, drift: local.pos - t.pos }
    }

    // Alone in the room: this player *is* the timeline. Instead of chasing
    // it (clock-sync adjustments would make it hunt and stutter), quietly
    // re-anchor the timeline to where we actually are.
    if (this.isLeader && this.peers.size === 0 && t.playing && local.playing && this.connected) {
      if (Math.abs(local.pos - t.pos) > 1) {
        const tl = this.state!.tl
        this.state = { ...this.state!, tl: { ...tl, pos: local.pos, at: this.transport.now(), n: tl.n + 1, by: this.me } }
        this.publishState()
      }
      return { play: true, rate: 1, seek: null, drift: 0 }
    }

    let c = correction(local, t, canNudge)
    if (c.seek !== null && t.playing) {
      if (c.drift < 0 && (notMoving || this.stalled)) {
        // Behind because we're stuck, not slow: jumping ahead would only
        // land on more unbuffered video. Report the stall instead.
        c = { ...c, seek: null, rate: 1 }
      } else if (now - this.lastHardSeek < HARD_SEEK_COOLDOWN_MS && this.lastHardSeekN === this.state?.tl.n && Math.abs(c.drift) < 15) {
        // A jump is still loading: steer with speed instead of jumping again.
        c = { ...c, seek: null, rate: c.drift > 0 ? 0.9 : 1.1 }
      } else {
        this.lastHardSeek = now
        this.lastHardSeekN = this.state?.tl.n ?? 0
        this.hardSyncs = [...this.hardSyncs.filter(x => now - x < 30_000), now]
        if (this.hardSyncs.length >= 3) { this.hardSyncs = []; this.events.onStruggling?.() }
      }
    }
    if (c.seek !== null) this.resetProgress(now)
    return c
  }

  private resetProgress(now: number) { this.samples = []; this.wantSince = now }

  /** No player yet / loading the room's media (counts as buffering). */
  setLoading(on: boolean, error: string | null = null) {
    this.loading = on
    this.loadingError = error
    this.publishBuffering()
  }

  private publishBuffering() {
    const on = this.loading || this.stalled
    if (on === this.myBuffering) return
    this.myBuffering = on
    if (this.connected) this.transport.send({ k: 'buf', on, error: this.loadingError })
  }

  get buffering() { return this.myBuffering }

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
  private lastResume = 0

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
    const cooling = now - this.lastResume < REHOLD_COOLDOWN_MS
    // Alone, there's nobody to hold the room for: the timeline just follows us.
    if (cfg.waitForAll && tl.playing && !cooling && (waitingOn.length || (meStalled && this.peers.size > 0)) && tl.media) {
      this.bumpAsLeader({ playing: false, hold: true })
    } else if (tl.hold && !tl.playing && !waitingOn.length && !meStalled) {
      this.lastResume = now
      this.bumpAsLeader({ playing: true, hold: false })
    } else if (now - this.lastSentTl > 30_000) {
      // Refresh the relay's copy now and then (cheap, one message).
      this.publishState()
    }
    this.leaderProbe()
  }

  // ── Periodic "where is everyone?" check ─────────────────────────────
  // Every PROBE_EVERY_MS the leader names a moment about PROBE_LEAD_MS ahead
  // on the shared clock ("at 08:00:20, tell me where you are"). Everyone
  // reports its position *at that moment*, so slower replies don't skew the
  // comparison. The leader is the reference: it tells the room each person's
  // gap, and if its own player has drifted from the timeline, the timeline
  // moves to the leader. Everyone then closes any gap on their own, smoothly
  // under HARD_SYNC_S and with a jump above it.
  private probe: { id: number; at: number; from: string; answered: boolean; own?: number; replies: Map<string, number>; n: number } | null = null
  private probeSeq = 0
  private lastProbe = 0
  /** Our gap to the leader at the last check (seconds, + = ahead). */
  myGap: number | null = null

  private leaderProbe() {
    const st = this.state!
    const tn = this.transport.now()
    const p = this.probe
    if (p && p.from === this.me) {
      // Someone changed playback during the check: the answers are stale.
      if (st.tl.n !== p.n || !st.tl.playing || st.tl.hold) { this.probe = null; return }
      if (tn >= p.at + PROBE_COLLECT_MS) this.finishProbe(p)
      return
    }
    if (Date.now() - this.lastProbe < PROBE_EVERY_MS || !st.tl.playing || st.tl.hold || !st.tl.media || this.peers.size === 0) return
    this.lastProbe = Date.now()
    const probe = { id: ++this.probeSeq, at: tn + PROBE_LEAD_MS, from: this.me, answered: false, replies: new Map<string, number>(), n: st.tl.n }
    this.probe = probe
    this.transport.send({ k: 'probe', id: probe.id, at: probe.at })
  }

  /** Called from sync(): once the agreed moment has passed, report where we were at it. */
  private answerProbe(local: { pos: number; playing: boolean }) {
    const p = this.probe
    if (!p || p.answered) return
    const tn = this.transport.now()
    if (tn < p.at) return
    if (tn > p.at + 8000) { if (p.from !== this.me) this.probe = null; return }
    p.answered = true
    const pos = local.playing ? local.pos - (tn - p.at) / 1000 : local.pos
    if (p.from === this.me) p.own = pos
    else this.transport.send({ k: 'probe-reply', id: p.id, pos }, { to: p.from })
  }

  private finishProbe(p: NonNullable<PartyCore['probe']>) {
    this.probe = null
    if (p.own === undefined || !this.state) return
    const gaps: Record<string, number> = {}
    for (const [id, pos] of p.replies) {
      const peer = this.peers.get(id)
      if (!peer) continue
      gaps[id] = Math.round((pos - p.own) * 100) / 100
      peer.gap = gaps[id]
    }
    this.myGap = 0
    this.transport.send({ k: 'probe-result', id: p.id, gaps })
    const tn = this.transport.now()
    const expected = positionAt(this.state.tl, p.at)
    if (Math.abs(p.own - expected) > REANCHOR_S && !this.myBuffering && !this.loading) {
      this.bumpAsLeader({ pos: p.own + Math.max(0, tn - p.at) / 1000 })
    }
    this.events.onChange?.()
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
