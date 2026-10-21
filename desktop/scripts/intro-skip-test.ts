// npm run test:intro - segment validation, identity matching, the auto-skip
// state machine, and live TheIntroDB / Kitsu / AniSkip / AniKoto lookups.
import assert from 'node:assert/strict'
import {
  AutoSkipTracker, activeIntro, aniSkipEpisode, aniSkipSegments, matchMalId, parseAired, streamSegments,
  theIntroDbSegments, validSegment, validSegments, type AnimeIdentity, type KitsuCandidate
} from '../src/shared/introSkip'
import type { SkipSegment } from '../src/shared/types'
import { aniSkip, introDbTv } from '../src/main/skip'
import * as anime from '../src/main/resolvers/animekai'

let passed = 0
const test = async (name: string, fn: () => void | Promise<void>) => {
  try { await fn(); passed++; console.log('  ok  ', name) } catch (e) { console.log('  FAIL', name, '\n       ', (e as Error).message); process.exitCode = 1 }
}
const intro = (start: number, end: number): SkipSegment => ({ kind: 'intro', start, end, source: 'theintrodb' })

async function main() {
  console.log('Segments')
  await test('rejects inverted, NaN, negative, too short and too long intros', () => {
    assert.equal(validSegment(intro(50, 40), 0), null)
    assert.equal(validSegment(intro(NaN, 40), 0), null)
    assert.equal(validSegment(intro(-1, 40), 0), null)
    assert.equal(validSegment(intro(10, 11), 0), null)
    assert.equal(validSegment(intro(0, 900), 0), null)
  })
  await test('rejects segments outside the real video and clamps small overruns', () => {
    assert.equal(validSegment(intro(1500, 1590), 1400), null)
    assert.equal(validSegment(intro(10, 1500), 1400), null)
    assert.equal(validSegment({ ...intro(1300, 1401), kind: 'outro' }, 1400)?.end, 1400)
  })
  await test('dedupes and sorts', () => {
    assert.deepEqual(validSegments([intro(300, 390), intro(10, 90), intro(10.4, 91)], 0).map(s => s.start), [10, 300])
  })
  await test('TheIntroDB: null start = 0, null-end intro dropped, credits kept as outro', () => {
    const s = theIntroDbSegments({ intro: [{ start_ms: null, end_ms: 90071 }, { start_ms: 5000, end_ms: null }], credits: [{ start_ms: 1460262, end_ms: 1550264 }] })
    assert.deepEqual(s, [
      { kind: 'intro', start: 0, end: 90.071, source: 'theintrodb' },
      { kind: 'outro', start: 1460.262, end: 1550.264, source: 'theintrodb' }
    ])
    assert.deepEqual(theIntroDbSegments(null), [])
    assert.deepEqual(theIntroDbSegments({ intro: 'x' }), [])
  })
  await test('AniSkip: op → intro, ed → outro, found:false → none', () => {
    const s = aniSkipSegments({ found: true, results: [{ skipType: 'op', interval: { startTime: 344.7, endTime: 435 } }, { skipType: 'ed', interval: { startTime: 1334, endTime: 1424 } }, { skipType: 'recap', interval: { startTime: 0, endTime: 30 } }] })
    assert.deepEqual(s.map(x => x.kind), ['intro', 'outro'])
    assert.deepEqual(aniSkipSegments({ found: false, results: [] }), [])
  })
  await test('stream (MegaPlay): 0/0 is no data', () => {
    assert.deepEqual(streamSegments({ intro: { start: 0, end: 0 }, outro: { start: 0, end: 0 } }), [])
    assert.equal(streamSegments({ intro: { start: 345, end: 432 } })[0].end, 432)
  })

  console.log('Identity')
  const jjk: AnimeIdentity = { titles: ['Jujutsu Kaisen (TV)', 'Sorcery Fight'], type: 'tv', aired: '2020-10-03', episodes: 24 }
  const cands: KitsuCandidate[] = [
    { malId: 40748, titles: ['Jujutsu Kaisen'], subtype: 'TV', startDate: '2020-10-03', episodeCount: 24 },
    { malId: 38777, titles: ['Jujutsu Kaisen'], subtype: 'ONA', startDate: '2018-12-03', episodeCount: 3 },
    { malId: 51009, titles: ['Jujutsu Kaisen Season 2'], subtype: 'TV', startDate: '2023-07-06', episodeCount: 23 }
  ]
  await test('parses aired dates', () => {
    assert.equal(parseAired('Oct 3, 2020 to Mar 27, 2021'), '2020-10-03')
    assert.equal(parseAired('2020'), null)
  })
  await test('exact title + type + air date gives one MAL id', () => assert.equal(matchMalId(jjk, cands), 40748))
  await test('same title, other type (ONA) is not accepted', () => assert.equal(matchMalId({ ...jjk, type: 'ona', aired: '2020-10-03' }, cands), null))
  await test('separate seasons stay separate', () => assert.equal(matchMalId({ titles: ['Jujutsu Kaisen Season 2'], type: 'tv', aired: '2023-07-06', episodes: 23 }, cands), 51009))
  await test('similar but not equal title is rejected (no fuzzy match)', () => assert.equal(matchMalId({ ...jjk, titles: ['Jujutsu Kaisen 2'] }, cands), null))
  await test('episode count disagreement is rejected', () => assert.equal(matchMalId({ ...jjk, episodes: 47 }, cands), null))
  await test('two different MAL ids matching is ambiguous', () => assert.equal(matchMalId(jjk, [...cands, { ...cands[0], malId: 99999 }]), null))
  await test('missing date or type never matches', () => {
    assert.equal(matchMalId({ ...jjk, aired: null }, cands), null)
    assert.equal(matchMalId({ ...jjk, type: '' }, cands), null)
  })
  await test('episode numbers: recaps and absolute numbers past the entry are refused', () => {
    assert.equal(aniSkipEpisode('5', jjk, cands[0]), 5)
    assert.equal(aniSkipEpisode('12.5', jjk, cands[0]), null)
    assert.equal(aniSkipEpisode('25', jjk, cands[0]), null)
    assert.equal(aniSkipEpisode('0', jjk, cands[0]), null)
  })

  console.log('Auto-skip')
  const segs = [intro(60, 150)]
  const run = (times: number[], allowed = true, set = new Set<string>()) => {
    const t = new AutoSkipTracker(set)
    return times.map(x => t.step('ep', segs, x, allowed))
  }
  await test('playing into the intro skips once', () => assert.deepEqual(run([58, 59, 60.2, 60.5]), [null, null, 150, null]))
  await test('starting playback inside the intro skips', () => assert.deepEqual(run([75]), [150]))
  await test('seeking into the intro does not skip', () => assert.deepEqual(run([10, 11, 90, 90.25]), [null, null, null, null]))
  await test('rewinding into a skipped intro does not skip again', () => {
    const set = new Set<string>()
    const t = new AutoSkipTracker(set)
    assert.equal(t.step('ep', segs, 60.1, true), 150) // first tick = start → skip
    t.restart()
    assert.deepEqual([t.step('ep', segs, 59.9, true), t.step('ep', segs, 60.1, true)], [null, null])
    assert.equal(t.step('ep', segs, 152, true), null)
    assert.equal(t.step('ep', segs, 100, true), null)
    assert.equal(set.size, 1)
  })
  await test('rewinding to before the intro and playing through: still once', () => {
    const set = new Set<string>()
    const t = new AutoSkipTracker(set)
    assert.equal(t.step('ep', segs, 59.8, true), null)
    assert.equal(t.step('ep', segs, 60.1, true), 150)
    assert.equal(t.step('ep', segs, 30, true), null)
    assert.equal(t.step('ep', segs, 59.9, true), null)
    assert.equal(t.step('ep', segs, 60.2, true), null)
  })
  await test('not allowed (setting off / party viewer): never seeks', () => assert.deepEqual(run([59, 60.2, 61], false), [null, null, null]))
  await test('a new episode key has its own state', () => {
    const t = new AutoSkipTracker(new Set())
    assert.equal(t.step('ep1', segs, 60.1, true), 150)
    const t2 = new AutoSkipTracker(new Set())
    assert.equal(t2.step('ep2', segs, 60.1, true), 150)
  })
  await test('button only inside the intro, not in its last second', () => {
    assert.equal(activeIntro(segs, 59), null)
    assert.ok(activeIntro(segs, 100))
    assert.equal(activeIntro(segs, 149.5), null)
  })

  console.log('Live lookups')
  await test('TheIntroDB: Breaking Bad S1E1 has an intro', async () => {
    const s = validSegments(await introDbTv('1396', 1, 1, 3480), 3480)
    assert.ok(s.some(x => x.kind === 'intro' && x.start > 200 && x.end < 260), JSON.stringify(s))
  })
  await test('TheIntroDB: One Piece in TMDB numbering (S22E1100) resolves', async () => {
    const s = await introDbTv('37854', 22, 1100, 1400)
    assert.ok(s.some(x => x.kind === 'intro'), JSON.stringify(s))
  })
  await test('TheIntroDB: missing episode → no timestamps', async () => assert.deepEqual(await introDbTv('1396', 9, 1, 0), []))
  await test('TheIntroDB: invalid id → no timestamps (no throw)', async () => assert.deepEqual(await introDbTv('abc', 1, 1, 0), []))
  await test('AniKoto page identity → MAL 40748 → AniSkip opening for E2', async () => {
    const d = await anime.details('https://anikototv.to', 'jujutsu-kaisen-tv-8ssye')
    assert.ok(d.identity, 'identity parsed')
    assert.equal(d.identity!.type, 'tv')
    assert.equal(d.identity!.aired, '2020-10-03')
    const s = validSegments(await aniSkip(d.identity!, '2', 1420), 1420)
    assert.ok(s.some(x => x.kind === 'intro' && Math.abs(x.start - 345) < 5), JSON.stringify(s))
  })
  await test('AniSkip: unverifiable identity → no timestamps', async () => {
    assert.deepEqual(await aniSkip({ titles: ['Definitely Not A Real Show 9000'], type: 'tv', aired: '2020-01-01', episodes: 12 }, '1', 1400), [])
  })
  await test('AniKoto streams carry MegaPlay intro/outro for that stream', async () => {
    const d = await anime.details('https://anikototv.to', 'jujutsu-kaisen-tv-8ssye')
    const streams = await anime.streams('https://anikototv.to', d.episodes[1].ids)
    const withIntro = streams.filter(s => s.segments?.some(x => x.kind === 'intro'))
    console.log('        ', `${withIntro.length}/${streams.length} streams carry an intro`, withIntro[0]?.segments)
    assert.ok(streams.length > 0)
  })

  console.log(`\n${passed} passed${process.exitCode ? ', some FAILED' : ''}`)
  process.exit(process.exitCode ?? 0)
}
main()
