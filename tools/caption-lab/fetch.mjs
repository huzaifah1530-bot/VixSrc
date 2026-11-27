// Downloads a stretch of a VixSrc episode's English audio (decrypted, as
// raw ADTS AAC) and its English subtitles, for the caption lab. Nothing
// here ships in the app; it only feeds the speaker tests.
//
//   node fetch.mjs <tmdbId> <season> <episode> <fromSeconds> <toSeconds> <outName>
import { createDecipheriv } from 'node:crypto'
import { writeFileSync, mkdirSync } from 'node:fs'

const [id, season, episode, from, to, name] = process.argv.slice(2)
const UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1'
const get = async (url, headers = {}) => {
  for (let attempt = 0; ; attempt++) {
    try {
      const r = await fetch(url, { headers: { 'User-Agent': UA, ...headers }, signal: AbortSignal.timeout(30000) })
      if (!r.ok) throw new Error(`${r.status} ${url.slice(0, 90)}`)
      return r
    } catch (e) { if (attempt >= 3) throw e; await new Promise(r => setTimeout(r, 1500)) }
  }
}
const lines = t => t.split('\n').map(s => s.trim())

const page = `https://vixsrc.to/tv/${id}/${season}/${episode}`
const api = await (await get(`https://vixsrc.to/api/tv/${id}/${season}/${episode}`, { Referer: page })).json()
const html = await (await get(new URL(api.src, page).href, { Referer: page })).text()
const token = html.match(/'token':\s*'([^']+)'/)[1], expires = html.match(/'expires':\s*'([^']+)'/)[1]
const vid = html.match(/id:\s*'(\d+)'/)[1]
const masterUrl = `https://vixsrc.to/playlist/${vid}?token=${token}&expires=${expires}&lang=en`
const master = await (await get(masterUrl)).text()
const media = (type, lang) => master.split('\n').find(l => l.startsWith(`#EXT-X-MEDIA:TYPE=${type}`) && new RegExp(`LANGUAGE="${lang}"`).test(l))?.match(/URI="([^"]+)"/)?.[1]

// ---- Audio
const audioUrl = media('AUDIO', 'eng')
if (!audioUrl) throw new Error('no English audio rendition')
const aList = lines(await (await get(audioUrl)).text())
const keyLine = aList.find(l => l.startsWith('#EXT-X-KEY'))
let key = null, iv = null
if (keyLine) {
  key = Buffer.from(await (await get(new URL(keyLine.match(/URI="([^"]+)"/)[1], audioUrl).href)).arrayBuffer())
  iv = keyLine.match(/IV=0x([0-9a-fA-F]+)/)?.[1]
}
const segs = []
let t = 0, seq = parseInt(aList.find(l => l.startsWith('#EXT-X-MEDIA-SEQUENCE'))?.split(':')[1] ?? '0')
for (let i = 0; i < aList.length; i++) if (aList[i].startsWith('#EXTINF:')) {
  const d = parseFloat(aList[i].slice(8)); segs.push({ url: new URL(aList[i + 1], audioUrl).href, start: t, d, seq: seq++ }); t += d
}
const chosen = segs.filter(s => s.start + s.d > +from && s.start < +to)
function adts(ts) {
  let pmt = -1; const types = {}; const out = []; let cur = null, pid0 = -1
  for (let o = 0; o + 188 <= ts.length; o += 188) {
    const pusi = (ts[o + 1] & 0x40) !== 0, pid = ((ts[o + 1] & 0x1f) << 8) | ts[o + 2], afc = (ts[o + 3] >> 4) & 3
    let p = o + 4
    if (afc === 0 || afc === 2) continue
    if (afc === 3) p += 1 + ts[o + 4]
    if (pid === 0 && pusi) { p += 1 + ts[p]; pmt = ((ts[p + 10] & 0x1f) << 8) | ts[p + 11]; continue }
    if (pid === pmt && pusi) {
      p += 1 + ts[p]; const len = ((ts[p + 1] & 0x0f) << 8) | ts[p + 2], info = ((ts[p + 10] & 0x0f) << 8) | ts[p + 11]
      let q = p + 12 + info; const end = p + 3 + len - 4
      while (q < end) { types[((ts[q + 1] & 0x1f) << 8) | ts[q + 2]] = ts[q]; q += 5 + (((ts[q + 3] & 0x0f) << 8) | ts[q + 4]) }
      continue
    }
    if (types[pid] !== 0x0f) continue
    if (pusi) { if (cur) out.push(Buffer.concat(cur)); cur = []; pid0 = pid }
    if (cur && pid === pid0) cur.push(ts.subarray(p, o + 188))
  }
  if (cur) out.push(Buffer.concat(cur))
  return Buffer.concat(out.map(b => b.subarray(9 + b[8])))
}
const parts = []
for (const s of chosen) {
  let data = Buffer.from(await (await get(s.url)).arrayBuffer())
  if (key) {
    const v = iv ? Buffer.from(iv.padStart(32, '0'), 'hex') : (() => { const b = Buffer.alloc(16); b.writeUInt32BE(s.seq, 12); return b })()
    const d = createDecipheriv('aes-128-cbc', key, v); data = Buffer.concat([d.update(data), d.final()])
  }
  parts.push(adts(data))
}
mkdirSync('lab', { recursive: true })
writeFileSync(`lab/${name}.aac`, Buffer.concat(parts))
const audioStart = chosen[0].start

// ---- Subtitles
const subUrl = media('SUBTITLES', 'eng')
if (!subUrl) throw new Error('no English subtitles')
const sList = lines(await (await get(subUrl)).text())
let vtt = ''
for (const l of sList) if (l && !l.startsWith('#')) vtt += '\n' + await (await get(new URL(l, subUrl).href)).text()
const secs = s => { const p = s.replace(',', '.').split(':').map(Number); return p.reduce((a, v) => a * 60 + v, 0) }
const cues = []
const blocks = vtt.replace(/\r/g, '').split(/\n\n+/)
for (const b of blocks) {
  const ls = b.split('\n'); const i = ls.findIndex(l => l.includes('-->'))
  if (i < 0) continue
  const [a, z] = ls[i].split('-->').map(x => x.trim().split(/\s+/)[0])
  const text = ls.slice(i + 1).join('\n').replace(/<[^>]+>/g, '').replace(/\{[^}]+\}/g, '').trim()
  const start = secs(a), end = secs(z)
  if (text && end > start && start >= +from && end <= +to) cues.push({ start, end, text })
}
cues.sort((x, y) => x.start - y.start)
writeFileSync(`lab/${name}.json`, JSON.stringify({ audioStart, cues }))
console.log(`${name}: ${chosen.length} audio segments from ${audioStart}s, ${cues.length} subtitle cues, ${cues.filter(c => /^\s*[-–—]/m.test(c.text) && c.text.split('\n').filter(l => /^\s*[-–—]/.test(l)).length >= 2).length} two-speaker cues`)
