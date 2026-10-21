// Runs the bundled Nuvio providers (providers/bundle/nuvio-bundle.js) in a
// bare `vm` context. The context deliberately has none of Node's globals,
// so providers see the same environment as JavaScriptCore on iOS; the
// runtime polyfills URL/Buffer/etc. and calls back here for real HTTP.
// Mirrors providers/host-node.mjs (used by `npm test` in providers/).
import vm from 'node:vm'
import bundle from '../../../../providers/bundle/nuvio-bundle.js?raw'
import type { ExternalSubtitle, ResolvedStream } from '@shared/types'
import { parseNuvioRoute } from '@shared/nuvio'

interface RawStream {
  name: string; title: string; url: string; quality: string; size: string
  headers: Record<string, string>
  subtitles: { url: string; name: string; language: string; headers: Record<string, string> }[]
}
interface Api {
  run(id: string, tmdbId: string, type: string, season: number | null, episode: number | null, timeoutMs: number,
    cb: (err: string | null, json: string | null) => void): void
}

const utf8 = new TextDecoder('utf-8', { fatal: true })
const debug = !!process.env.VELA_PROVIDER_DEBUG

async function hostFetch(raw: string): Promise<string> {
  const req = JSON.parse(raw) as {
    url: string; method: string; headers: [string, string][]; body?: string; bodyBase64?: string; redirect: string; timeout: number
  }
  const headers = new Headers()
  for (const [k, v] of req.headers ?? []) { try { headers.append(k, v) } catch { /* invalid header */ } }
  const res = await fetch(req.url, {
    method: req.method,
    headers,
    body: req.bodyBase64 != null ? Buffer.from(req.bodyBase64, 'base64') : req.body,
    redirect: req.redirect === 'manual' ? 'manual' : req.redirect === 'error' ? 'error' : 'follow',
    signal: AbortSignal.timeout(Math.min(req.timeout || 20_000, 60_000))
  })
  const bytes = Buffer.from(await res.arrayBuffer())
  const pairs: [string, string][] = []
  res.headers.forEach((v, k) => { if (k !== 'set-cookie') pairs.push([k, v]) })
  for (const c of res.headers.getSetCookie()) pairs.push(['set-cookie', c])
  const out: Record<string, unknown> = { status: res.status, statusText: res.statusText, url: res.url || req.url, redirected: res.redirected, headers: pairs }
  try { out.text = utf8.decode(bytes) } catch { out.base64 = bytes.toString('base64') }
  return JSON.stringify(out)
}

let api: Api | null = null
function runtime(): Api {
  if (api) return api
  const timers = new Map<number, NodeJS.Timeout>()
  let next = 1
  const host = {
    fetch: (raw: string, cb: (err: string | null, res: string | null) => void) => {
      hostFetch(raw).then(r => cb(null, r), (e: Error & { cause?: Error }) => cb(String(e?.cause?.message || e?.message || e), null))
    },
    setTimeout: (fn: () => void, ms: number) => {
      const id = next++
      timers.set(id, setTimeout(() => { timers.delete(id); fn() }, ms))
      return id
    },
    clearTimeout: (id: number) => { clearTimeout(timers.get(id)); timers.delete(id) },
    log: (level: string, msg: string) => { if (debug || level === 'fatal') console.log(`[nuvio:${level}] ${msg}`) }
  }
  const context = vm.createContext({ __velaHost: host })
  vm.runInContext(bundle, context, { filename: 'nuvio-bundle.js' })
  api = context.__velaNuvio as Api
  return api
}

function run(id: string, tmdbId: string, type: string, season: number | null, episode: number | null): Promise<RawStream[]> {
  return new Promise((resolve, reject) => {
    runtime().run(id, tmdbId, type, season, episode, 45_000, (err, json) => {
      if (err) reject(new Error(err)); else resolve(JSON.parse(json ?? '[]'))
    })
  })
}

const QUALITY = /\b(2160p|4k|1440p|1080p|720p|480p|360p)\b/i

/** One label per stream: provider's own name, then quality/size if missing. */
function label(s: RawStream, fallback: string): string {
  let name = (s.name || s.title || fallback).replace(/\s+/g, ' ').trim()
  const known = (v: string) => (v && !/^(unknown|n\/a|auto)$/i.test(v.trim()) ? v.trim() : '')
  const quality = known(s.quality)
  const extra = [quality && !name.toLowerCase().includes(quality.toLowerCase()) ? quality : '', known(s.size)].filter(Boolean)
  if (extra.length) name += ` · ${extra.join(' · ')}`
  return name.slice(0, 120)
}

export async function nuvioStreams(pageUrl: string): Promise<ResolvedStream[] | null> {
  const route = parseNuvioRoute(pageUrl)
  if (!route) return null
  const raw = await run(route.provider.id, route.tmdbId, route.type, route.season, route.episode)
  return raw.map(s => {
    const subtitles: ExternalSubtitle[] = s.subtitles
      .filter(t => /\.vtt(\?|$)/i.test(t.url) || !/\.(srt|ass|ssa)(\?|$)/i.test(t.url))
      .map(t => ({ label: t.name || t.language || 'Subtitles', url: t.url, referer: t.headers.Referer ?? t.headers.referer ?? '' }))
    const quality = (s.quality || QUALITY.exec(`${s.name} ${s.title}`)?.[1] || '').toLowerCase()
    return {
      id: s.url,
      name: label(s, route.provider.name),
      url: s.url,
      requestHeaders: s.headers,
      quality: quality || undefined,
      subtitles
    }
  })
}
