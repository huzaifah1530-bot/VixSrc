// SRT subtitles → the caption lab's cue JSON (audio starts at 0).
//   node srt2json.mjs <in.srt> <out.json>
import { readFileSync, writeFileSync } from 'node:fs'
const [input, output] = process.argv.slice(2)
const secs = s => s.replace(',', '.').split(':').map(Number).reduce((a, v) => a * 60 + v, 0)
const cues = []
for (const block of readFileSync(input, 'utf8').replace(/\r/g, '').split(/\n\n+/)) {
  const lines = block.split('\n'); const i = lines.findIndex(l => l.includes('-->'))
  if (i < 0) continue
  const [a, z] = lines[i].split('-->').map(x => x.trim().split(/\s+/)[0])
  const text = lines.slice(i + 1).join('\n').replace(/<[^>]+>/g, '').trim()
  if (text) cues.push({ start: secs(a), end: secs(z), text })
}
writeFileSync(output, JSON.stringify({ audioStart: 0, cues }))
console.log(`${cues.length} cues`)
