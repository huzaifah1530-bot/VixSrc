// Multi-viewer Watch Together simulation against a real relay
// (`wrangler dev` locally, or the deployed one). Each viewer is a real
// PartyCore + PartyConnection with a simulated video player.
// Run: npm run test:party [-- wss://relay]
import assert from 'node:assert/strict'
import { PartyCore, WAIT_LIMIT_MS, type PartyMedia } from '../src/shared/party'
import { PartyConnection, newIdentity, newInvite, type Invite } from '../src/shared/partyClient'

const relay = process.argv[2] ?? 'http://127.0.0.1:8787'
const sleep = (ms: number) => new Promise(r => setTimeout(r, ms))
let passed = 0
const ok = (msg: string) => { passed++; console.log('ok', msg) }

const movie: PartyMedia = { kind: 'tmdb', key: 'movie:157336', item: { type: 'movie', tmdbId: '157336', title: 'Interstellar' }, season: null, episode: null, server: 'VixSrc' }
const ep = (n: number): PartyMedia => ({ kind: 'tmdb', key: `tv:1399:1:${n}`, item: { type: 'tv', tmdbId: '1399', title: 'GoT' }, season: 1, episode: n, server: 'VixSrc' })

class Viewer {
  core: PartyCore
  conn: PartyConnection
  pos = 0
  playing = false
  rate = 1
  /** < 1 simulates a device whose playback can't keep real time */
  speed = 1
  stalled = false
  media: string | null = null
  duration = 7200
  toasts: string[] = []
  seeks = 0
  /** Briefly stall after every seek, like a real player re-buffering. */
  seekStallMs = 0
  private stallUntil = 0
  private lastTick = Date.now()
  loop: ReturnType<typeof setInterval>[] = []
  constructor(readonly name: string, invite: Invite, readonly id = newIdentity()) {
    this.conn = new PartyConnection(relay, invite, id.peer, id.secret)
    this.core = new PartyCore(id.peer, name, 'sim', this.conn, {
      onMedia: m => { this.media = m?.key ?? null; this.pos = 0 },
      onToast: t => this.toasts.push(t),
      nextMedia: m => (m.kind === 'tmdb' && m.episode ? ep(m.episode + 1) : null)
    })
    this.conn.core = this.core
  }
  async start() {
    await this.conn.open()
    // "Video" clock.
    this.loop.push(setInterval(() => {
      const now = Date.now(), dt = (now - this.lastTick) / 1000
      this.lastTick = now
      if (this.playing && !this.stalled && now > this.stallUntil) this.pos += dt * this.rate * this.speed
      if (this.pos >= this.duration && this.playing) { this.playing = false; this.core.ended() }
    }, 100))
    // App sync loop (same cadence as the real players).
    this.loop.push(setInterval(() => {
      if (!this.core.state) return
      const c = this.core.sync({ pos: this.pos, playing: this.playing, ended: this.pos >= this.duration })
      if (c.seek !== null) { this.pos = c.seek; this.stallUntil = Date.now() + this.seekStallMs }
      this.playing = c.play
      this.rate = c.rate
      if (c.seek !== null) this.seeks++
      this.core.tick()
    }, 500))
    await until(() => this.conn.status === 'connected', 8000, `${this.name} connect`)
  }
  stop() { this.loop.forEach(clearInterval); this.conn.close() }
  /** Simulates the network dropping without a clean close. */
  drop() { this.conn.reconnectNow() }
}

async function until(pred: () => boolean, ms: number, what: string) {
  const end = Date.now() + ms
  while (!pred()) { if (Date.now() > end) throw new Error('timeout: ' + what); await sleep(100) }
}
const spread = (vs: Viewer[]) => Math.max(...vs.map(v => v.pos)) - Math.min(...vs.map(v => v.pos))

/** The bug report: a host alone in a party kept freezing. */
async function soloHost() {
  const solo = new Viewer('Solo', newInvite())
  solo.seekStallMs = 1500
  await solo.start()
  solo.core.create(movie, 0, true)
  await sleep(6000)
  // A short network hiccup: alone, nobody is waited for — the room's
  // timeline simply follows this player.
  solo.stalled = true
  await sleep(5000)
  assert.equal(solo.core.state!.tl.hold, false, 'never holds when alone')
  assert.ok(Math.abs(solo.core.target().pos - solo.pos) < 1.5, 'timeline followed the stuck player')
  solo.stalled = false
  await sleep(2000)
  const n = solo.core.state!.tl.n
  const p0 = solo.pos
  const trace: string[] = []
  let lastN = n
  const tr = setInterval(() => { const t = solo.core.state!.tl; if (t.n !== lastN) { lastN = t.n; trace.push(`n=${t.n} playing=${t.playing} hold=${t.hold} pos=${solo.pos.toFixed(1)} buf=${solo.core.buffering}`) } }, 100)
  await sleep(10000)
  clearInterval(tr)
  if (trace.length) console.log(trace.join('\n'))
  assert.equal(solo.core.state!.tl.n, n, 'no more holds after recovering')
  assert.ok(solo.pos - p0 > 9, 'kept playing ' + (solo.pos - p0))
  ok(`a host alone never holds or chases the clock; plays smoothly after a hiccup (${(solo.pos - p0).toFixed(1)}s in 10s, ${solo.seeks} jumps)`)
  assert.equal(solo.seeks, 0, 'no jumps when alone')
  solo.stop()
}

async function main() {
  await soloHost()
  const invite = newInvite()
  const host = new Viewer('Host', invite)
  await host.start()
  host.core.create(movie, 0, false)
  const a = new Viewer('Amy', invite), b = new Viewer('Ben', invite)
  await a.start(); await b.start()
  await until(() => a.core.state?.tl.media?.key === movie.key && b.media === movie.key, 5000, 'joiners get media')
  await until(() => [a, b].every(v => host.core.peers.get(v.id.peer)?.name === v.name), 5000, 'roster names')
  ok('joiners receive the room and the roster')

  host.core.play()
  await sleep(4000)
  assert.ok([host, a, b].every(v => v.playing), 'all playing')
  assert.ok(spread([host, a, b]) < 0.5, 'in sync ' + spread([host, a, b]))
  ok(`play reaches everyone, spread ${spread([host, a, b]).toFixed(2)}s`)

  a.core.pause()
  await until(() => !host.playing && !b.playing, 3000, 'pause from viewer')
  ok('a viewer can pause for everyone (mode: everyone)')

  b.core.seek(1200); b.core.play()
  await until(() => [host, a, b].every(v => v.playing && Math.abs(v.pos - 1200) < 2), 4000, 'seek+play')
  ok('seek from another viewer moves everyone')

  // ── Lag: Ben's device plays 8% slow ────────────────────────────────
  b.speed = 0.92
  await sleep(8000)
  assert.ok(Math.abs(b.pos - host.pos) < 1, 'slow device kept up ' + (b.pos - host.pos))
  ok(`slow device is kept in step by speed nudges (off by ${(b.pos - host.pos).toFixed(2)}s)`)
  b.speed = 1

  // ── Ben falls far behind (e.g. jumped back on his own) ─────────────
  b.pos -= 30
  await until(() => Math.abs(b.pos - host.pos) < 1, 3000, 'hard resync')
  ok('a viewer 30s behind is jumped back into sync')

  // ── A small gap (under 5s) eases out with speed, without a jump ────
  const jumps = b.seeks
  b.pos -= 2.5
  await until(() => Math.abs(b.pos - host.pos) < 1, 25000, 'smooth catch-up')
  assert.equal(b.seeks, jumps, 'a 2.5s gap must not cause a jump')
  ok(`a viewer 2.5s behind catches up smoothly, no jump (now ${(b.pos - host.pos).toFixed(2)}s off)`)

  // ── The 30-second check: the host asks, everyone reports the same moment ──
  host.core.peers.get(a.id.peer)!.gap = null
  a.core.myGap = null
  await until(() => host.core.peers.get(a.id.peer)?.gap != null && a.core.myGap != null, 50000, 'sync check result')
  const amyGap = host.core.peers.get(a.id.peer)!.gap!
  assert.ok(Math.abs(amyGap) < 1.5, 'Amy is in step, gap ' + amyGap)
  ok(`the periodic check reports each viewer's gap to the host's player (Amy ${amyGap.toFixed(2)}s)`)

  // ── Stall: wait for everyone, then give up after the limit ────────
  b.stalled = true
  await until(() => !host.playing && host.core.state!.tl.hold, 7000, 'room holds for stalled viewer')
  assert.equal(host.core.waitingOn()[0]?.name, 'Ben')
  ok('room pauses while Ben buffers ("waiting for Ben")')
  b.stalled = false
  await until(() => host.playing && a.playing && b.playing, 4000, 'room resumes')
  ok('room resumes by itself when Ben recovers')

  b.stalled = true
  await until(() => host.core.state!.tl.hold, 9000, 'hold again')
  await until(() => host.playing && !host.core.state!.tl.hold, WAIT_LIMIT_MS + 5000, 'gives up waiting')
  assert.ok(host.toasts.some(t => t.includes('Carrying on without Ben')))
  ok('after the wait limit the room carries on without the stalled viewer')
  b.stalled = false
  await until(() => Math.abs(b.pos - host.pos) < 1 && b.playing, 5000, 'stalled viewer catches up')
  ok('the stalled viewer catches up on recovery')

  // ── Permissions ────────────────────────────────────────────────────
  host.core.configure({ mode: 'host' })
  await until(() => a.core.state!.cfg.mode === 'host', 3000, 'cfg propagates')
  assert.equal(a.core.pause(), false)
  ok('host-only mode blocks a viewer locally')
  // A modified client tries anyway, sending a forged state directly.
  const forged = { ...a.core.state!, tl: { ...a.core.state!.tl, playing: false, n: a.core.state!.tl.n + 50, by: a.id.peer } }
  a.conn.send({ k: 'state', s: forged }, { keep: true })
  await sleep(1500)
  assert.ok(host.playing && b.playing, 'forged pause ignored')
  ok('a forged pause from a viewer without control is ignored by everyone')
  // A viewer can't change settings either.
  a.conn.send({ k: 'state', s: { ...host.core.state!, cfg: { ...host.core.state!.cfg, mode: 'everyone', n: 99 } } })
  await sleep(1000)
  assert.equal(b.core.state!.cfg.mode, 'host'); ok('a viewer cannot change the host settings')

  host.core.configure({ mode: 'select', allowed: [b.id.peer] })
  await until(() => b.core.state!.cfg.mode === 'select', 3000, 'select mode')
  assert.equal(b.core.pause(), true)
  await until(() => !host.playing && !a.playing, 3000, 'allowed viewer pauses')
  assert.equal(a.core.play(), false)
  ok('selected viewers get control, others still don\'t')
  b.core.play()
  await until(() => host.playing, 3000, 'replay')

  // ── Host's connection drops ─────────────────────────────────────────
  const before = a.pos
  host.stop() // host device is gone entirely
  await until(() => !a.core.peers.has(host.id.peer), 8000, 'host leave seen')
  assert.equal(a.core.leader, a.id.peer, 'longest-present viewer leads')
  await sleep(2000)
  assert.ok(a.playing && b.playing && a.pos > before + 1, 'playback continued without host')
  ok('host drops: playback carries on, Amy (longest present) takes over')
  assert.equal(a.core.pause(), true, 'acting leader can control in select mode')
  await until(() => !b.playing, 3000, 'acting leader pause')
  a.core.play()
  await until(() => b.playing, 3000, 'acting leader play')
  ok('the acting leader has control while the host is away')

  // Host comes back with the same identity.
  const host2 = new Viewer('Host', invite, host.id)
  await host2.start()
  await until(() => host2.playing && Math.abs(host2.pos - a.pos) < 1, 6000, 'host rejoins in sync')
  await until(() => a.core.leader === host.id.peer, 3000, 'host is leader again')
  assert.ok(host2.core.isHost)
  ok('the host returns, lands in sync, and is in charge again')

  // ── A viewer's own connection drops and returns ────────────────────
  b.drop()
  assert.equal(b.core.pause(), false, 'no actions while offline')
  host2.core.seek(3000)
  await until(() => b.conn.status === 'reconnecting', 3000, 'ben notices')
  await until(() => b.conn.status === 'connected', 10000, 'ben reconnects')
  await until(() => Math.abs(b.pos - host2.pos) < 1.5, 5000, 'ben resynced after reconnect')
  ok('a viewer who drops can\'t act while offline and rejoins on the room\'s current position')

  // ── Late joiner ────────────────────────────────────────────────────
  const c = new Viewer('Cat', invite)
  await c.start()
  await until(() => c.playing && Math.abs(c.pos - host2.pos) < 1, 5000, 'late joiner in sync')
  ok('a late joiner lands on the current position')

  // ── Concurrent actions converge ───────────────────────────────────
  host2.core.configure({ mode: 'everyone' })
  await until(() => c.core.state!.cfg.mode === 'everyone', 3000, 'everyone mode')
  a.core.seek(4000); c.core.seek(5000)
  await sleep(2500)
  const views = [host2, a, b, c]
  if (!views.every(v => v.core.state!.tl.n === views[0].core.state!.tl.n)) console.log(views.map(v => `${v.name} n=${v.core.state!.tl.n} by=${v.core.state!.tl.by.slice(0, 4)} pos=${v.pos.toFixed(0)}`).join(' | '))
  assert.ok(views.every(v => v.core.state!.tl.n === views[0].core.state!.tl.n && v.core.state!.tl.by === views[0].core.state!.tl.by), 'same winner')
  assert.ok(spread(views) < 1.5, 'converged ' + spread(views))
  ok(`two people seeking at once converge on one result (${views[0].core.state!.tl.pos.toFixed(0)}s)`)

  // ── Only the host changes what's playing ──────────────────────────
  assert.equal(a.core.setMedia(ep(7)), false)
  await sleep(1000)
  assert.ok(views.every(v => v.media === movie.key || v.core.state!.tl.media?.key === movie.key), 'viewer media change ignored')
  const forgedMedia = { ...a.core.state!, tl: { ...a.core.state!.tl, media: ep(9), n: a.core.state!.tl.n + 9, by: a.id.peer } }
  a.conn.send({ k: 'state', s: forgedMedia }, { keep: true })
  await sleep(1200)
  assert.ok(host2.core.state!.tl.media?.key === movie.key, 'forged media change ignored')
  ok('viewers can control playback but only the host changes the title (forged attempts ignored)')

  // Host goes back to browsing: the room stays, media is "none".
  host2.core.setMedia(null)
  await until(() => views.every(v => v.core.state!.tl.media === null && !v.core.target().playing), 3000, 'browsing')
  ok('host going back to browsing keeps the party open for everyone')

  // ── Episode end: leader advances exactly once ─────────────────────
  host2.core.setMedia(ep(1))
  await until(() => views.every(v => v.media === 'tv:1399:1:1' && v.pos < 5), 4000, 'episode 1 everywhere')
  for (const v of views) v.duration = 30
  host2.core.seek(26)
  try {
    await until(() => views.every(v => v.media === 'tv:1399:1:2'), 12000, 'advanced to episode 2')
  } catch (e) {
    const tl = host2.core.state!.tl
    console.log('tl', JSON.stringify({ ...tl, media: tl.media?.key }), 'waiting', host2.core.waitingOn().map(p => p.name), views.map(v => `${v.name}:${v.pos.toFixed(1)}/${v.playing}/buf=${v.core.buffering}/media=${v.media}`).join(' '))
    throw e
  }
  await sleep(2000)
  assert.ok(views.every(v => v.media === 'tv:1399:1:2'), 'not advanced twice')
  ok('at the end of an episode the room moves to the next one, once')

  for (const v of [host2, a, b, c]) v.stop()
  console.log(`\n${passed} party scenarios passed`)
  process.exit(0)
}
main().catch(e => { console.error('FAIL', e); process.exit(1) })
