// Smoke test against `wrangler dev`: join, relay, keep, direct, leave, ping.
import assert from 'node:assert/strict'
const base = process.argv[2] ?? 'ws://127.0.0.1:8787'
const room = 'TESTROOM' + Math.random().toString(36).slice(2, 8)

function open(peer) {
  const ws = new WebSocket(`${base}/room/${room}?peer=${peer}&s=secret-for-${peer}`)
  const q = [], waiters = []
  ws.onmessage = e => { const m = e.data === 'pong' ? { pong: true } : JSON.parse(e.data); const w = waiters.shift(); w ? w(m) : q.push(m) }
  const next = (ms = 4000) => q.length ? Promise.resolve(q.shift()) : new Promise((res, rej) => { const t = setTimeout(() => rej(new Error(peer + ' timeout')), ms); waiters.push(m => { clearTimeout(t); res(m) }) })
  return new Promise(res => { ws.onopen = () => res({ ws, next, send: o => ws.send(typeof o === 'string' ? o : JSON.stringify(o)) }) })
}

const a = await open('peerAAAA')
const wa = await a.next(); assert.equal(wa.sys, 'welcome'); assert.equal(wa.peers.length, 0); assert.equal(wa.keep, null)
console.log('ok first peer welcomed')

a.send({ d: 'timeline-1', keep: true })
const b = await open('peerBBBB')
const wb = await b.next()
assert.equal(wb.peers[0].peer, 'peerAAAA'); assert.equal(JSON.parse(wb.keep).d, 'timeline-1')
assert.equal((await a.next()).sys, 'join')
console.log('ok late joiner gets the cached timeline and the room is told')

b.send({ d: 'pause' })
const got = await a.next(); assert.equal(got.from, 'peerBBBB'); assert.equal(got.d, 'pause')
console.log('ok broadcast relayed with sender id')

const c = await open('peerCCCC'); await c.next(); await a.next(); await b.next()
a.send({ d: 'just-for-c', to: 'peerCCCC' })
assert.equal((await c.next()).d, 'just-for-c')
await assert.rejects(b.next(600)); console.log('ok direct message only reaches its target')

c.send({ t: 'time', c: 123 }); const t = await c.next(); assert.equal(t.sys, 'time'); assert.equal(t.echo, 123); assert.ok(t.now > 0)
console.log('ok clock sync echo')

c.send('ping'); assert.equal((await c.next()).pong, true); console.log('ok auto-response ping')

c.ws.close(); assert.equal((await a.next()).sys, 'leave'); console.log('ok leave announced')

a.send({ d: 'x'.repeat(20000) }); await assert.rejects(b.next(600)); console.log('ok oversized message dropped')
const thief = new WebSocket(`${base}/room/${room}?peer=peerAAAA&s=not-the-real-secret-xx`)
const stolen = await new Promise(res => { thief.onopen = () => res(true); thief.onerror = () => res(false); thief.onclose = () => res(false) })
assert.equal(stolen, false); console.log('ok another device cannot take an existing peer id')
console.log('\nrelay smoke test passed'); process.exit(0)
