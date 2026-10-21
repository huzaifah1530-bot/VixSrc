// Runs every provider (or the ids given as args) against a movie and a TV
// episode and probes the first stream, printing a pass/fail table.
//   node test.mjs [id...] [--verbose]
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createRuntime } from './host-node.mjs'

const ROOT = dirname(fileURLToPath(import.meta.url))
const verbose = process.argv.includes('--verbose')
const only = process.argv.slice(2).filter(a => !a.startsWith('--'))
const rt = createRuntime(join(ROOT, 'bundle/nuvio-bundle.js'), {
  log: (level, msg) => { if (verbose || level === 'fatal') console.log(`    [${level}] ${msg.slice(0, 300)}`) }
})

// Oppenheimer; Breaking Bad S1E1; Frieren S1E1 for the anime providers.
const CASES = [
  { label: 'movie', args: ['872585', 'movie'] },
  { label: 'tv', args: ['1396', 'tv', 1, 1] },
  { label: 'anime', args: ['209867', 'tv', 1, 1] }
]
const ANIME = new Set(['animepahe', 'hianime', 'kurage', 'anizone', 'vidnest-anime'])

async function probe(stream) {
  try {
    const res = await fetch(stream.url, { headers: { ...stream.headers, Range: 'bytes=0-2047' }, signal: AbortSignal.timeout(15000) })
    const type = res.headers.get('content-type') ?? ''
    const body = Buffer.from(await res.arrayBuffer())
    const hls = body.subarray(0, 7).toString() === '#EXTM3U'
    return `${res.status} ${hls ? 'HLS' : type.split(';')[0] || '?'}`
  } catch (e) { return `probe failed: ${e.message}` }
}

const ids = only.length ? only : rt.ids()
const rows = []
await Promise.all(ids.map(async id => {
  const cases = ANIME.has(id) ? CASES.filter(c => c.label === 'anime') : CASES.filter(c => c.label !== 'anime')
  for (const c of cases) {
    const t0 = Date.now()
    try {
      const streams = await rt.run(id, ...c.args)
      const first = streams[0]
      rows.push({ id, case: c.label, streams: streams.length, secs: ((Date.now() - t0) / 1000).toFixed(1), first: first ? `${await probe(first)} ${first.url.slice(0, 70)}` : '' })
    } catch (e) {
      rows.push({ id, case: c.label, streams: 'ERR', secs: ((Date.now() - t0) / 1000).toFixed(1), first: e.message.slice(0, 100) })
    }
  }
}))
rows.sort((a, b) => a.id.localeCompare(b.id) || a.case.localeCompare(b.case))
for (const r of rows) console.log(`${r.id.padEnd(15)} ${r.case.padEnd(6)} ${String(r.streams).padStart(3)} ${r.secs.padStart(5)}s  ${r.first}`)
process.exit(0)
