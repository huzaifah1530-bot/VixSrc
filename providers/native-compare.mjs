// Diagnostic: runs the vendored providers directly in Node (real require,
// real globals) to tell provider breakage apart from runtime gaps.
//   node native-compare.mjs [id...]
import { createRequire } from 'node:module'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = dirname(fileURLToPath(import.meta.url))
const require = createRequire(join(ROOT, 'package.json'))
const manifest = JSON.parse(readFileSync(join(ROOT, 'vendor/manifest.json'), 'utf8'))
const only = process.argv.slice(2)
const ANIME = new Set(['animepahe', 'hianime', 'kurage', 'anizone', 'vidnest-anime'])
console.log = () => {}; console.warn = () => {}; console.info = () => {}; console.debug = () => {}
const errLog = console.error; console.error = () => {}
const rows = []
await Promise.all(manifest.scrapers.filter(s => !only.length || only.includes(s.id)).map(async s => {
  const mod = require(join(ROOT, 'vendor', s.filename))
  const cases = ANIME.has(s.id) ? [['209867', 'tv', 1, 1]] : [['872585', 'movie'], ['1396', 'tv', 1, 1]]
  for (const c of cases) {
    try {
      const r = await Promise.race([mod.getStreams(...c), new Promise((_, j) => setTimeout(() => j(new Error('timeout')), 45000))])
      rows.push({ id: s.id, type: c[1], streams: Array.isArray(r) ? r.length : 'n/a' })
    } catch (e) { rows.push({ id: s.id, type: c[1], streams: 'ERR ' + e.message.slice(0, 60) }) }
  }
}))
rows.sort((a, b) => a.id.localeCompare(b.id) || a.type.localeCompare(b.type))
errLog(rows.map(r => `${r.id.padEnd(15)} ${r.type.padEnd(6)} ${r.streams}`).join('\n'))
process.exit(0)
