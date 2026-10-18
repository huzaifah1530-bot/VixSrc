// Simulates the iOS client against a running desktop app (dev build with
// VELA_LINK_TEST=<file>). Exercises discovery, pairing, the encrypted
// channel, remote commands, playback state, stale-command rejection,
// reconnection without scanning, and a sync round trip.
import assert from 'node:assert/strict'
import { connect, type Socket } from 'node:net'
import { readFileSync } from 'node:fs'
import { createHmac, createPublicKey, diffieHellman, generateKeyPairSync, hkdfSync, randomBytes, randomUUID, type KeyObject } from 'node:crypto'
import { Bonjour } from 'bonjour-service'
import { FrameReader, SessionCipher, frame } from '../src/main/link/crypto'

const linkFile = process.argv[2]
const rawPub = (k: KeyObject) => Buffer.from(k.export({ format: 'jwk' }).x!, 'base64url')
const dh = (priv: KeyObject, pub: Buffer) => diffieHellman({ privateKey: priv, publicKey: createPublicKey({ key: { kty: 'OKP', crv: 'X25519', x: pub.toString('base64url') }, format: 'jwk' }) })
const phone = generateKeyPairSync('x25519')
const deviceId = randomUUID()

class Client {
  socket!: Socket
  cipher: SessionCipher | null = null
  queue: any[] = []
  waiters: ((m: any) => void)[] = []
  closed = false
  async open(host: string, port: number) {
    this.socket = connect(port, host)
    await new Promise<void>((res, rej) => { this.socket.once('connect', res); this.socket.once('error', rej) })
    const reader = new FrameReader()
    this.socket.on('data', (c: Buffer) => {
      for (const f of reader.push(c)) {
        const m = JSON.parse((this.cipher ? this.cipher.open(f) : f).toString('utf8'))
        const w = this.waiters.shift(); w ? w(m) : this.queue.push(m)
      }
    })
    this.socket.on('close', () => { this.closed = true })
  }
  send(m: object) { const b = Buffer.from(JSON.stringify(m)); this.socket.write(frame(this.cipher ? this.cipher.seal(b) : b)) }
  next(timeout = 8000): Promise<any> {
    if (this.queue.length) return Promise.resolve(this.queue.shift())
    return new Promise((res, rej) => { const t = setTimeout(() => rej(new Error('timeout')), timeout); this.waiters.push(m => { clearTimeout(t); res(m) }) })
  }
  async until(pred: (m: any) => boolean, timeout = 20000) {
    const end = Date.now() + timeout
    for (;;) {
      const m = await this.next(Math.max(1, end - Date.now()))
      if (process.env.SIM_VERBOSE) console.log('  <-', JSON.stringify(m).slice(0, 160))
      if (pred(m)) return m
    }
  }
  async hello(deskPub: Buffer, opts: { code?: Buffer; auto?: boolean }) {
    const eph = generateKeyPairSync('x25519'), n = randomBytes(16)
    const pub = rawPub(phone.publicKey), ephPub = rawPub(eph.publicKey)
    const proof = opts.code ? createHmac('sha256', opts.code).update(Buffer.concat([Buffer.from('vixscr-pair'), pub, ephPub, n])).digest().toString('base64') : undefined
    this.send({ t: 'hello', v: 1, deviceId, name: 'Sim iPhone', pub: pub.toString('base64'), eph: ephPub.toString('base64'), nonce: n.toString('base64'), auto: !!opts.auto, proof })
    const ok = await this.next()
    if (ok.t !== 'hello-ok') return ok
    const keys = Buffer.from(hkdfSync('sha256', Buffer.concat([dh(phone.privateKey, deskPub), dh(eph.privateKey, Buffer.from(ok.eph, 'base64'))]), Buffer.concat([n, Buffer.from(ok.nonce, 'base64')]), Buffer.from('vixscr-link-v1'), 64))
    this.cipher = new SessionCipher(keys.subarray(0, 32), keys.subarray(32))
    return this.next()
  }
}

async function main() {
  const url = new URL(readFileSync(linkFile, 'utf8'))
  const q = url.searchParams
  const deskPub = Buffer.from(q.get('k')!, 'base64url'), code = Buffer.from(q.get('c')!, 'base64url')
  const port = Number(q.get('p'))

  // Discovery
  const found = await new Promise<any>((res, rej) => {
    const b = new Bonjour()
    const t = setTimeout(() => { b.destroy(); rej(new Error('no bonjour')) }, 8000)
    b.find({ type: 'vixscr' }, s => { if (s.txt?.id === q.get('d')) { clearTimeout(t); b.destroy(); res(s) } })
  })
  console.log('ok bonjour found', found.name, found.port)
  assert.equal(found.port, port)

  // Wrong code is refused
  let c = new Client(); await c.open('127.0.0.1', port)
  assert.equal((await c.hello(deskPub, { code: randomBytes(16) })).code, 'bad-proof'); console.log('ok wrong code rejected')

  // Pair
  c = new Client(); await c.open('127.0.0.1', port)
  const welcome = await c.hello(deskPub, { code })
  assert.equal(welcome.t, 'welcome'); assert.equal(welcome.firstPairing, true); console.log('ok paired, encrypted channel up')

  // Remote playback
  c.send({ t: 'cmd', id: 'c1', action: 'play-tmdb', item: { type: 'movie', tmdbId: '157336', title: 'Interstellar', description: '', year: '2014', popularity: 0 } })
  const ack = await c.until(m => m.t === 'ack' && m.id === 'c1'); assert.equal(ack.ok, true, ack.error)
  const playing = await c.until(m => m.t === 'state' && m.s.open && m.s.mode === 'native' && m.s.duration > 0, 45000)
  console.log('ok desktop playing natively:', playing.s.title, '@', playing.s.position.toFixed(1), '/', playing.s.duration.toFixed(0))
  const session = playing.s.session

  c.send({ t: 'cmd', id: 'c2', action: 'seek', to: 600, session })
  assert.equal((await c.until(m => m.t === 'ack' && m.id === 'c2')).ok, true)
  const seeked = await c.until(m => m.t === 'state' && m.s.position >= 595, 15000)
  console.log('ok seek reflected in state:', seeked.s.position.toFixed(1))

  c.send({ t: 'cmd', id: 'c3', action: 'pause', session })
  await c.until(m => m.t === 'state' && m.s.playing === false, 10000); console.log('ok pause reflected')
  c.send({ t: 'cmd', id: 'c3', action: 'play', session })
  assert.equal((await c.until(m => m.t === 'ack' && m.id === 'c3')).error, 'duplicate'); console.log('ok duplicate command ignored')
  c.send({ t: 'cmd', id: 'c4', action: 'skip', by: 30, session: 'movie:999' })
  assert.equal((await c.until(m => m.t === 'ack' && m.id === 'c4')).error, 'stale'); console.log('ok stale command rejected')

  // Sync round trip
  c.send({ t: 'sync-config', enabled: true })
  c.send({ t: 'sync-doc', mode: 'merge', reply: true, doc: { v: 1, settings: { seekInterval: { v: 15, at: Date.now() } }, favorites: [{ key: 'movie:27205', item: { type: 'movie', tmdbId: '27205', title: 'Inception', description: '', year: '2010', popularity: 0 }, at: Date.now() }] } })
  const back = await c.until(m => m.t === 'sync-doc' && m.doc.favorites.some((f: any) => f.key === 'movie:27205'))
  assert.ok(back.doc.favorites.some((f: any) => f.key === 'movie:27205' && !f.del)); assert.equal(back.doc.settings.seekInterval.v, 15)
  console.log('ok sync merged on desktop and returned', back.doc.favorites.length, 'favourites')

  // Disconnect, playback continues, reconnect without scanning
  c.send({ t: 'cmd', id: 'c3b', action: 'play', session })
  await c.until(m => m.t === 'state' && m.s.playing === true, 10000)
  c.socket.destroy()
  await new Promise(r => setTimeout(r, 3000))
  c = new Client(); await c.open('127.0.0.1', port)
  const again = await c.hello(deskPub, { auto: true })
  assert.equal(again.t, 'welcome'); assert.equal(again.firstPairing, false); assert.equal(again.syncEnabled, true)
  const st = await c.until(m => m.t === 'state' && m.s.open)
  assert.ok(st.s.position > 600, 'playback kept going'); console.log('ok reconnected without code; desktop still playing at', st.s.position.toFixed(1))

  c.send({ t: 'cmd', id: 'c5', action: 'stop', session: st.s.session })
  await c.until(m => m.t === 'state' && !m.s.open); console.log('ok stop')

  // Forget from the phone side; the next hello must be refused.
  c.send({ t: 'revoke' })
  await new Promise(r => setTimeout(r, 800))
  c = new Client(); await c.open('127.0.0.1', port)
  assert.equal((await c.hello(deskPub, {})).code, 'unpaired'); console.log('ok revoked pairing needs a new scan')
  console.log('\nphone simulation passed')
  process.exit(0)
}
main().catch(e => { console.error('FAIL', e); process.exit(1) })
