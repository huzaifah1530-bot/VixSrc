// End-to-end: a scripted host runs a party on the deployed relay; the real
// desktop app (dev build, isolated profile) joins via its open-party path.
// We read the app's actual <video> state from the probe file.
import assert from 'node:assert/strict'
import { readFileSync, writeFileSync } from 'node:fs'
import { spawn } from 'node:child_process'
import { PartyCore, positionAt, type PartyMedia } from '../src/shared/party'
import { PARTY_RELAY, PartyConnection, inviteLink, newIdentity, newInvite } from '../src/shared/partyClient'

const probe = process.argv[2], electron = process.argv[3], profile = process.argv[4]
const sleep = (ms: number) => new Promise(r => setTimeout(r, ms))
const read = () => { try { return JSON.parse(readFileSync(probe, 'utf8')).s as { t: number; paused: boolean; rate: number; title: string } | null } catch { return null } }
async function until(pred: () => boolean, ms: number, what: string) {
  const end = Date.now() + ms
  while (!pred()) { if (Date.now() > end) throw new Error('timeout: ' + what + ' last=' + JSON.stringify(read())); await sleep(250) }
}

const movie: PartyMedia = { kind: 'tmdb', key: 'movie:157336', item: { tmdbId: '157336', type: 'movie', title: 'Interstellar', description: '', year: '2014', popularity: 0 }, season: null, episode: null, server: 'VixSrc' }

async function main() {
  writeFileSync(probe, '{}')
  const invite = newInvite(), id = newIdentity()
  const conn = new PartyConnection(PARTY_RELAY, invite, id.peer, id.secret)
  const host = new PartyCore(id.peer, 'Script host', 'sim', conn, {})
  conn.core = host
  await conn.open()
  await until(() => conn.status === 'connected', 10000, 'host connect')
  host.create(movie, 600, true)
  const tick = setInterval(() => host.tick(), 1000)

  const app = spawn(electron, ['.'], { env: { ...process.env, VELA_PARTY_JOIN: inviteLink(invite).replace(PARTY_RELAY + '/p/', 'vela://party/'), VELA_PARTY_PROBE: probe, VELA_USER_DATA: profile }, stdio: 'ignore' })
  try {
    await until(() => host.peers.size === 1 && [...host.peers.values()][0].name === 'PC', 30000, 'app joins')
    console.log('ok desktop app joined from a vela://party link')
    await until(() => !!read() && read()!.title === 'Interstellar' && !read()!.paused, 60000, 'app plays the room title')
    const target = () => positionAt(host.state!.tl, conn.now())
    await until(() => Math.abs(read()!.t - target()) < 1.5, 30000, 'app in sync')
    console.log(`ok app opened Interstellar and is in sync (app ${read()!.t.toFixed(1)}s vs room ${target().toFixed(1)}s)`)

    host.pause()
    await until(() => read()!.paused, 5000, 'pause reaches app')
    console.log('ok pause from the room pauses the app')
    host.seek(1800); host.play()
    await until(() => !read()!.paused && Math.abs(read()!.t - target()) < 1.5, 30000, 'seek reaches app')
    console.log(`ok seek + play reaches the app (${read()!.t.toFixed(1)}s)`)

    host.configure({ mode: 'host' })
    await sleep(1500)
    await sleep(6000)
    assert.ok(Math.abs(read()!.t - target()) < 1.5, 'still in sync after settings change')
    console.log('ok stays in sync for a while; drift ' + (read()!.t - target()).toFixed(2) + 's')
    console.log('\nparty end-to-end passed')
  } finally {
    clearInterval(tick); conn.close(); app.kill()
  }
  process.exit(0)
}
main().catch(e => { console.error('FAIL', e); process.exit(1) })
