// Port of iOS StreamURLExtractor: turns an embed page URL into direct
// HLS/MP4 sources for the native player. Empty result = use the embed.
import type { ResolvedStream } from '@shared/types'
import { isNuvioUrl } from '@shared/nuvio'
import { MOBILE_UA, DESKTOP_UA, firstMatch, getJson, getResponse, getText } from '../http'
import { nuvioStreams } from '../providers/nuvio'

const stream = (name: string, url: string, headers: Record<string, string>): ResolvedStream => ({
  id: url, name, url, requestHeaders: headers, subtitles: []
})

export async function resolveStreams(pageUrl: string): Promise<ResolvedStream[]> {
  let url: URL
  try { url = new URL(pageUrl) } catch { return [] }
  const lower = pageUrl.toLowerCase()
  const ext = url.pathname.split('.').pop()?.toLowerCase() ?? ''

  if (['mp4', 'm3u8', 'm3u', 'webm', 'mov'].includes(ext) || lower.includes('.m3u8?') || lower.includes('.mp4?')) {
    return [stream('Direct stream', pageUrl, {})]
  }
  // Nuvio provider: run it and never scrape the script URL as a page.
  if (isNuvioUrl(pageUrl)) return (await nuvioStreams(pageUrl)) ?? []
  const host = url.hostname.toLowerCase()
  if (host.includes('vixsrc')) {
    const s = await vixSrc(url).catch(() => null)
    if (s?.length) return s
  }
  if (host.includes('cinezo')) {
    const s = await cinezo(url).catch(() => null)
    if (s?.length) return s
  }
  const direct = await fromHtml(url).catch(() => null)
  return direct ? [stream('Direct stream', direct, { 'User-Agent': MOBILE_UA })] : []
}

/** Normalises both `/movie/id` and `/embed/movie/id`. */
function mediaRoute(url: URL): string[] | null {
  const parts = url.pathname.split('/').filter(Boolean)
  const i = parts.findIndex(p => p.toLowerCase() === 'movie' || p.toLowerCase() === 'tv')
  return i < 0 ? null : parts.slice(i).map(p => decodeURIComponent(p))
}

// ── VixSrc: /api token → embed HTML → signed master playlist ──────────
async function vixSrc(page: URL): Promise<ResolvedStream[] | null> {
  const route = mediaRoute(page)
  if (!route || route.length < 2) return null
  let endpoint: string
  if (route[0].toLowerCase() === 'movie') endpoint = `/api/movie/${route[1]}`
  else if (route.length >= 4) endpoint = `/api/tv/${route[1]}/${route[2]}/${route[3]}`
  else return null

  const headers = { 'User-Agent': MOBILE_UA, Referer: page.href }
  const api = await getJson<{ src?: string }>(`${page.protocol}//${page.host}${endpoint}`, headers, 15_000)
  if (!api.src) return null
  const embedUrl = new URL(api.src, page)
  const html = await getText(embedUrl.href, headers, 15_000)
  return playlistUrls(html, embedUrl)
}

function playlistUrls(html: string, embedUrl: URL): ResolvedStream[] | null {
  const raw = firstMatch(/(?:window\.)?masterPlaylist\s*=\s*\{[\s\S]*?url\s*:\s*['"]([^'"]+)['"]/i, html)
  if (!raw) return null
  const master = new URL(raw, embedUrl)
  const extra: [string, string][] = []
  const params = firstMatch(/masterPlaylist\s*=\s*\{[\s\S]*?params\s*:\s*\{([\s\S]*?)\}[^}]*url/i, html) ?? ''
  for (const m of params.matchAll(/['"]([^'"]+)['"]\s*:\s*['"]([^'"]*)['"]/g)) {
    if (m[2]) extra.push([m[1], m[2]])
  }
  const lang = embedUrl.searchParams.get('lang')
  if (lang) extra.push(['lang', lang])
  extra.push(['h', '1'])
  extra.forEach(([k, v]) => master.searchParams.append(k, v))

  const headers = { 'User-Agent': MOBILE_UA }
  const out: ResolvedStream[] = []
  for (const m of html.matchAll(/\{\s*['"]name['"]\s*:\s*['"]([^'"]+)['"][\s\S]*?['"]url['"]\s*:\s*['"]([^'"]+)['"]/gi)) {
    try {
      const raw = m[2].replace(/\\\//g, '/').replace(/\\u0026/gi, '&').replace(/&amp;/g, '&')
      const u = new URL(raw, embedUrl)
      extra.forEach(([k, v]) => u.searchParams.append(k, v))
      out.push({ ...stream(m[1], u.href, headers), id: m[1] })
    } catch { /* skip */ }
  }
  if (!out.length) out.push({ ...stream('Auto', master.href, headers), id: 'master' })
  return out
}

// ── Cinezo: JSON resolvers used by its web player ─────────────────────
const CINEZO_SOURCES = [
  { name: 'Berlin', base: 'https://proxy1.flikhub.net', source: 'berlin' },
  { name: 'Zendaya', base: 'https://proxy3.flikhub.net', source: 'zendaya' },
  { name: 'Sadie', base: 'https://proxy1.flikhub.net', source: 'cinefreak' },
  { name: 'Jennifer', base: 'https://punkflix.net', source: 'jennifer' }
]

async function cinezo(page: URL): Promise<ResolvedStream[] | null> {
  const route = mediaRoute(page)
  if (!route || route.length < 2) return null
  const [type, id, season, episode] = route
  if (type === 'tv' && (!season || !episode)) return null

  const results = await Promise.all(CINEZO_SOURCES.map(async src => {
    let endpoint: string
    if (src.base.includes('punkflix.net')) {
      endpoint = type === 'tv' ? `${src.base}/tv/${id}/${season}/${episode}.json` : `${src.base}/movie/${id}.json`
    } else {
      const u = new URL(`${src.base}/${type}`)
      u.searchParams.set('id', id); u.searchParams.set('mode', 'json')
      u.searchParams.set('sources', src.source); u.searchParams.set('hevc', '1')
      if (type === 'tv') { u.searchParams.set('season', season); u.searchParams.set('episode', episode) }
      endpoint = u.href
    }
    try {
      const json = await getJson(endpoint, { 'User-Agent': DESKTOP_UA, Accept: 'application/json', Referer: page.href })
      return { src, urls: mediaUrls(json) }
    } catch { return { src, urls: [] as string[] } }
  }))

  const out: ResolvedStream[] = []
  for (const { src, urls } of results) {
    urls.forEach((u, i) => {
      if (out.some(s => s.url === u)) return
      out.push(stream(i === 0 ? src.name : `${src.name} ${i + 1}`, u, { 'User-Agent': DESKTOP_UA }))
    })
  }
  return out.length ? out : null
}

function mediaUrls(value: unknown, acc: string[] = []): string[] {
  if (typeof value === 'string') {
    const s = value.replace(/\\\//g, '/')
    if (/^https?:\/\//i.test(s) && /\.m3u8|\.mp4|\/stream|\/file|\/remux|\/hls/i.test(s) && !acc.includes(s)) acc.push(s)
  } else if (Array.isArray(value)) value.forEach(v => mediaUrls(v, acc))
  else if (value && typeof value === 'object') Object.values(value).forEach(v => mediaUrls(v, acc))
  return acc
}

// ── Generic HTML scrape ───────────────────────────────────────────────
async function fromHtml(page: URL): Promise<string | null> {
  const html = await getText(page.href, { 'User-Agent': MOBILE_UA, Accept: 'text/html,application/xhtml+xml' }, 15_000)
  const patterns = [
    /https?:\/\/[^"'\s]+(?:\.m3u8|\.mp4)[^"'\s]*/i,
    /"(https?:\/\/[^"]+\/(?:playlist|manifest|master)\.m3u8[^"]*)"/i,
    /src="(https?:\/\/[^"]+\.mp4[^"]*)"/i
  ]
  for (const p of patterns) {
    const m = p.exec(html)
    if (!m) continue
    const candidate = (m[1] ?? m[0]).trim().replace(/\\\//g, '/').replace(/&amp;/g, '&')
    try {
      const res = await getResponse(candidate, { Range: 'bytes=0-1', 'User-Agent': MOBILE_UA }, 5_000)
      res.body?.cancel().catch(() => {})
      return candidate
    } catch { /* try next */ }
  }
  return null
}
