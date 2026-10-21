// Diagnostic: follows each provider stream the way a player would
// (playlist → variant → first segment, or first bytes of a file) and
// reports what actually comes back.  node playback-probe.mjs [id...]
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createRuntime } from './host-node.mjs'

const ROOT = dirname(fileURLToPath(import.meta.url))
const rt = createRuntime(join(ROOT, 'bundle/nuvio-bundle.js'))
const ids = process.argv.slice(2).length ? process.argv.slice(2) : ['castle', 'vidlink', 'streamflix', 'dvdplay', 'uhdmovies', '4khdhub', 'moviesdrive', 'movieblast']

async function get(url, headers, range = 'bytes=0-4095') {
  try {
    const r = await fetch(url, { headers: { ...headers, Range: range }, signal: AbortSignal.timeout(15000), redirect: 'follow' })
    const b = Buffer.from(await r.arrayBuffer())
    return { status: r.status, type: r.headers.get('content-type') ?? '', url: r.url, body: b, acao: r.headers.get('access-control-allow-origin') }
  } catch (e) { return { status: 0, type: String(e.cause?.code ?? e.message), url, body: Buffer.alloc(0) } }
}
const sniff = b => {
  const s = b.subarray(0, 16)
  if (s.toString().startsWith('#EXTM3U')) return 'HLS'
  if (s[0] === 0x1a && s[1] === 0x45 && s[2] === 0xdf && s[3] === 0xa3) return 'MKV/WebM'
  if (s.subarray(4, 8).toString() === 'ftyp') return 'MP4'
  if (s[0] === 0x47) return 'MPEG-TS'
  if (/<html|<!doctype/i.test(b.subarray(0, 200).toString())) return 'HTML page'
  return 'unknown'
}

for (const id of ids) {
  let streams = []
  try { streams = await rt.run(id, '872585', 'movie') } catch (e) { console.log(`${id}: provider error ${e.message}`); continue }
  console.log(`\n== ${id}: ${streams.length} streams`)
  for (const s of streams.slice(0, 3)) {
    const h = s.headers
    const r = await get(s.url, h)
    let line = `  [${r.status}] ${sniff(r.body)} ${r.type.split(';')[0]}  headers=${Object.keys(h).join(',') || '-'}  ${s.url.slice(0, 80)}`
    if (sniff(r.body) === 'HLS') {
      const text = r.body.toString()
      const lines = text.split(/\r?\n/).filter(l => l && !l.startsWith('#'))
      let media = lines[0] ? new URL(lines[0], r.url).href : null
      if (media && /\.m3u8/i.test(media) || text.includes('#EXT-X-STREAM-INF')) {
        const v = await get(media, h)
        const vl = v.body.toString().split(/\r?\n/).filter(l => l && !l.startsWith('#'))
        line += `\n      variant [${v.status}] ${sniff(v.body)}`
        media = vl[0] ? new URL(vl[0], v.url).href : null
      }
      if (media) {
        const seg = await get(media, h, 'bytes=0-1023')
        const bare = await get(media, {}, 'bytes=0-1023')
        line += `\n      segment [${seg.status}] ${sniff(seg.body)} ${seg.type.split(';')[0]}  without headers [${bare.status}]  ${media.slice(0, 70)}`
      }
    }
    console.log(line)
  }
}
process.exit(0)
