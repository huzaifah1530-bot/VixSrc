// Merge-rule checks for shared/sync.ts. Run: npm run test:sync
import assert from 'node:assert/strict'
import { compactIfHuge, emptyDoc, mergeDocs as merge, replaceWith, shiftDoc, validateDoc, type ProgressRec, type SyncDoc } from '../src/shared/sync'

// Test timestamps are tiny, so pin "now" close to them (tombstones expire after 90 days).
const mergeDocs = (a: SyncDoc, b: SyncDoc, now = 100) => merge(a, b, now)

const doc = (patch: Partial<SyncDoc>): SyncDoc => ({ ...emptyDoc(), ...patch })
const prog = (p: Partial<ProgressRec>): ProgressRec => ({ id: 'movie:1', position: 0, duration: 6000, completed: false, watchedAt: 0, epoch: 0, at: 0, ...p })
const get = (d: SyncDoc, id = 'movie:1') => d.progress.find(p => p.id === id)!
let n = 0
const test = (name: string, fn: () => void) => { fn(); n++; console.log('ok', name) }

test('newest progress wins, even if it is earlier in the video', () => {
  const a = doc({ progress: [prog({ position: 1200, at: 10, watchedAt: 10 })] })
  const b = doc({ progress: [prog({ position: 300, at: 20, watchedAt: 20 })] })
  assert.equal(get(mergeDocs(a, b)).position, 300)
  assert.equal(get(mergeDocs(b, a)).position, 300)
})

test('the offline log example reduces to the last action per title', () => {
  const pcStranger = prog({ id: 'tv:1:1:1', position: 764, at: 44 })
  const pcAvengers = prog({ id: 'movie:2', position: 0, at: 45 })
  const phoneStrangerGone = prog({ id: 'tv:1:1:1', position: 764, del: true, at: 50 })
  const phoneAvengers = prog({ id: 'movie:2', position: 720, at: 49 })
  const m = mergeDocs(doc({ progress: [pcStranger, pcAvengers] }), doc({ progress: [phoneStrangerGone, phoneAvengers] }))
  assert.equal(get(m, 'movie:2').position, 720)
  assert.equal(get(m, 'tv:1:1:1').del, true)
})

test('a delete on one device loses to later watching on the other', () => {
  const deletedAt1 = doc({ progress: [prog({ del: true, at: 40 })] })
  const watchedAt2 = doc({ progress: [prog({ position: 100, at: 60 })] })
  const m = get(mergeDocs(deletedAt1, watchedAt2))
  assert.equal(m.del, undefined); assert.equal(m.position, 100)
  assert.equal(get(mergeDocs(watchedAt2, deletedAt1)).position, 100)
})

test('a delete newer than the watching wins', () => {
  const watched = doc({ progress: [prog({ position: 5000, at: 50 })] })
  const deleted = doc({ progress: [prog({ del: true, at: 60 })] })
  assert.equal(get(mergeDocs(watched, deleted)).del, true)
  assert.equal(get(mergeDocs(deleted, watched)).del, true)
})

test('timestamps from a device with a fast clock are shifted before merging', () => {
  // The phone's clock runs 5 minutes ahead: its 10:00 edit is really 9:55,
  // so the PC's 9:58 edit is newer and must win.
  const MIN = 60_000, base = 1_800_000_000_000
  const pc = doc({ progress: [prog({ position: 100, at: base + 58 * MIN, watchedAt: base + 58 * MIN })] })
  const phone = doc({ progress: [prog({ position: 999, at: base + 60 * MIN, watchedAt: base + 60 * MIN })] })
  const now = base + 120 * MIN
  assert.equal(get(merge(pc, phone, now)).position, 999) // unshifted: wrong winner
  assert.equal(get(merge(pc, shiftDoc(phone, -5 * MIN), now)).position, 100)
  assert.equal(shiftDoc(doc({ settings: { seekInterval: { v: 5, at: 1 } } }), 7).settings.seekInterval!.at, 1) // placeholders stay put
})

test('docs over 50 MB drop tombstones when that is enough, otherwise stay as they are', () => {
  const big = 'x'.repeat(2000)
  const fav = (i: number, del?: boolean) => ({ key: `movie:${i}`, item: { type: 'movie', tmdbId: String(i), title: big }, at: 5, ...(del ? { del } : {}) })
  const tombs = Array.from({ length: 30_000 }, (_, i) => fav(i, true))
  const d = doc({ favorites: [fav(-1), ...tombs] })
  const slim = compactIfHuge(d)
  assert.deepEqual(slim.favorites.map(f => f.key), ['movie:-1'])
  const small = doc({ favorites: [fav(1)] })
  assert.equal(compactIfHuge(small), small)
  const hugeLive = doc({ favorites: Array.from({ length: 30_000 }, (_, i) => fav(i)) })
  assert.equal(compactIfHuge(hugeLive), hugeLive)
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
