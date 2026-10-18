// Merge-rule checks for shared/sync.ts. Run: npm run test:sync
import assert from 'node:assert/strict'
import { emptyDoc, mergeDocs as merge, replaceWith, validateDoc, type ProgressRec, type SyncDoc } from '../src/shared/sync'

// Test timestamps are tiny, so pin "now" close to them (tombstones expire after 90 days).
const mergeDocs = (a: SyncDoc, b: SyncDoc, now = 100) => merge(a, b, now)

const doc = (patch: Partial<SyncDoc>): SyncDoc => ({ ...emptyDoc(), ...patch })
const prog = (p: Partial<ProgressRec>): ProgressRec => ({ id: 'movie:1', position: 0, duration: 6000, completed: false, watchedAt: 0, epoch: 0, at: 0, ...p })
const get = (d: SyncDoc, id = 'movie:1') => d.progress.find(p => p.id === id)!
let n = 0
const test = (name: string, fn: () => void) => { fn(); n++; console.log('ok', name) }

test('further progress wins within an epoch, either direction', () => {
  const a = doc({ progress: [prog({ position: 1200, at: 10, watchedAt: 10 })] })
  const b = doc({ progress: [prog({ position: 300, at: 20, watchedAt: 20 })] })
  assert.equal(get(mergeDocs(a, b)).position, 1200)
  assert.equal(get(mergeDocs(b, a)).position, 1200)
})

test('explicit restart (new epoch) beats stale further progress', () => {
  const stale = doc({ progress: [prog({ position: 5000, at: 50, epoch: 0 })] })
  const restarted = doc({ progress: [prog({ position: 40, at: 30, epoch: 30 })] })
  assert.equal(get(mergeDocs(stale, restarted)).position, 40)
  assert.equal(get(mergeDocs(restarted, stale)).position, 40)
})

test('mark unwatched (tombstone, new epoch) is not revived by stale progress', () => {
  const stale = doc({ progress: [prog({ position: 5000, completed: true, at: 50 })] })
  const unwatched = doc({ progress: [prog({ position: 5000, del: true, at: 40, epoch: 40 })] })
  assert.equal(get(mergeDocs(stale, unwatched)).del, true)
})

test('rewatch after unwatch survives the old tombstone', () => {
  const tomb = doc({ progress: [prog({ del: true, at: 40, epoch: 40 })] })
  const rewatch = doc({ progress: [prog({ position: 100, at: 60, epoch: 40 })] })
  const m = get(mergeDocs(tomb, rewatch))
  assert.equal(m.del, undefined); assert.equal(m.position, 100)
})

test('completed is sticky within an epoch', () => {
  const a = doc({ progress: [prog({ position: 5900, completed: true, at: 10 })] })
  const b = doc({ progress: [prog({ position: 5800, at: 20 })] })
  assert.equal(get(mergeDocs(b, a)).completed, true)
})

test('merge is idempotent and commutative', () => {
  const a = doc({ favorites: [{ key: 'movie:1', item: { type: 'movie', tmdbId: '1', title: 'A' }, at: 5 }], searches: [{ key: 'x', q: 'x', at: 1 }] })
  const b = doc({ favorites: [{ key: 'movie:2', item: { type: 'movie', tmdbId: '2', title: 'B' }, at: 6 }, { key: 'movie:1', item: { type: 'movie', tmdbId: '1', title: 'A' }, at: 9, del: true }] })
  const ab = mergeDocs(a, b, 100), ba = mergeDocs(b, a, 100)
  const norm = (d: SyncDoc) => JSON.stringify({ ...d, favorites: [...d.favorites].sort((x, y) => x.key.localeCompare(y.key)) })
  assert.equal(norm(ab), norm(ba))
  assert.equal(norm(mergeDocs(ab, ab, 100)), norm(ab))
  assert.equal(ab.favorites.find(f => f.key === 'movie:1')!.del, true)
})

test('same server added on both devices collapses to one', () => {
  const a = doc({ servers: [{ id: 'B-id', name: 'VixSrc', base: 'https://vixsrc.to', pos: 0, at: 1 }] })
  const b = doc({ servers: [{ id: 'A-id', name: 'VixSrc', base: 'https://vixsrc.to/', pos: 0, at: 1 }, { id: 'C', name: 'New', base: 'https://new.example', pos: 1, at: 2 }] })
  const live = mergeDocs(a, b).servers.filter(s => !s.del)
  assert.deepEqual(live.map(s => s.id).sort(), ['A-id', 'C'])
})

test('server edits and deletions propagate by time', () => {
  const a = doc({ servers: [{ id: 'S', name: 'Old', base: 'https://a.example', pos: 0, at: 1 }] })
  const edit = doc({ servers: [{ id: 'S', name: 'New', base: 'https://a.example', pos: 0, at: 5 }] })
  const del = doc({ servers: [{ id: 'S', name: 'New', base: 'https://a.example', pos: 0, at: 9, del: true }] })
  assert.equal(mergeDocs(a, edit).servers[0].name, 'New')
  assert.equal(mergeDocs(mergeDocs(a, edit), del).servers[0].del, true)
})

test('settings are last-writer-wins per field', () => {
  const a = doc({ settings: { credential: { v: 'old', at: 1 }, seekInterval: { v: 30, at: 9 } } })
  const b = doc({ settings: { credential: { v: 'new', at: 5 }, seekInterval: { v: 5, at: 2 } } })
  const m = mergeDocs(a, b)
  assert.equal(m.settings.credential!.v, 'new'); assert.equal(m.settings.seekInterval!.v, 30)
})

test('fresh copy tombstones destination-only records and then converges', () => {
  const dest = doc({ favorites: [{ key: 'movie:9', item: { type: 'movie', tmdbId: '9', title: 'Mine' }, at: 1 }] })
  const src = doc({ favorites: [{ key: 'movie:1', item: { type: 'movie', tmdbId: '1', title: 'Theirs' }, at: 1 }] })
  const r = replaceWith(dest, src, 50)
  assert.deepEqual(r.favorites.filter(f => !f.del).map(f => f.key), ['movie:1'])
  // Source learning the tombstone doesn't resurrect anything.
  assert.deepEqual(mergeDocs(src, r).favorites.filter(f => !f.del).map(f => f.key), ['movie:1'])
})

test('validation rejects malformed docs and bad servers', () => {
  assert.equal(validateDoc({ v: 1, servers: [{ id: 'x', name: 'n', base: 'javascript:alert(1)', pos: 0, at: 1 }] }), null)
  assert.equal(validateDoc({ v: 2 }), null)
  assert.equal(validateDoc({ v: 1, progress: [{ id: 'movie:1' }] }), null)
  assert.ok(validateDoc({ v: 1, settings: { seekInterval: { v: 7, at: 1 }, credential: { v: 'k', at: 1 } } })!.settings.seekInterval === undefined)
})

console.log(`\n${n} sync tests passed`)
