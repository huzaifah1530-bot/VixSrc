// Stremio stream addons: TMDB id → IMDb id → <addon>/stream/<type>/<id>.json.
// Only direct HTTP streams are kept (no torrents / external links), and each
// is probed so landing pages and dead links never reach the player.
import type { ResolvedStream } from '@shared/types'
import { parseAddonRoute } from '@shared/stremio'
import { DESKTOP_UA } from '../http'

const DEFAULT_TMDB_CREDENTIAL = 'ce5e1892fe2fdf9006a6b4dfabe1fea4'

interface AddonStream {
  name?: string; title?: string; description?: string; url?: string
  infoHash?: string; externalUrl?: string; ytId?: string
  behaviorHints?: { proxyHeaders?: { request?: Record<string, string> }; notWebReady?: boolean; filename?: string }
}

const imdbCache = new Map<string, string | null>()
const manifestCache = new Map<string, { at: number; prefixes: string[] | null }>()

async function imdbFor(type: 'movie' | 'tv', tmdbId: string, credential?: string): Promise<string | null> {
  const key = `${type}:${tmdbId}`
  if (imdbCache.has(key)) return imdbCache.get(key)!
  const cred = (credential || DEFAULT_TMDB_CREDENTIAL).trim()
  const url = new URL(`https://api.themoviedb.org/3/${type}/${encodeURIComponent(tmdbId)}/external_ids`)
  const headers: Record<string, string> = { accept: 'application/json' }
  if (cred.startsWith('eyJ') || cred.length > 60) headers.Authorization = 'Bearer ' + cred
  else url.searchParams.set('api_key', cred)
  const res = await fetch(url, { headers, signal: AbortSignal.timeout(10_000) })
  if (!res.ok) return null
  const id = ((await res.json()) as { imdb_id?: string }).imdb_id
  const value = typeof id === 'string' && /^tt\d+$/.test(id) ? id : null
  imdbCache.set(key, value)
  return value
}

/** Which id prefixes the addon accepts (null = unknown, assume IMDb). */
async function idPrefixes(root: string): Promise<string[] | null> {
  const hit = manifestCache.get(root)
  if (hit && Date.now() - hit.at < 3600_000) return hit.prefixes
  let prefixes: string[] | null = null
  try {
    const res = await fetch(`${root}/manifest.json`, { headers: { 'User-Agent': DESKTOP_UA }, signal: AbortSignal.timeout(30_000) })
    const m = (await res.json()) as { idPrefixes?: string[]; resources?: (string | { name: string; idPrefixes?: string[] })[] }
    const stream = m.resources?.find(r => typeof r === 'object' && r.name === 'stream') as { idPrefixes?: string[] } | undefined
    prefixes = stream?.idPrefixes ?? m.idPrefixes ?? null
  } catch { /* unknown */ }
  manifestCache.set(root, { at: Date.now(), prefixes })
  return prefixes
}

const HOP = new Set(['accept-encoding', 'connection', 'keep-alive', 'host', 'content-length', 'transfer-encoding', 'te', 'upgrade'])

/** What the URL really serves (first 2 KB), or null when it isn't video. */
export async function probeFormat(url: string, headers: Record<string, string>): Promise<ResolvedStream['format'] | null> {
  try {
    const res = await fetch(url, { headers: { ...headers, Range: 'bytes=0-2047' }, redirect: 'follow', signal: AbortSignal.timeout(8000) })
    if (res.status < 200 || res.status >= 400 || !res.body) return null
    const reader = res.body.getReader()
    const chunks: Uint8Array[] = []
    let size = 0
    while (size < 2048) { const { done, value } = await reader.read(); if (done) break; chunks.push(value); size += value.length }
    reader.cancel().catch(() => {})
    const b = Buffer.concat(chunks)
    const type = res.headers.get('content-type') ?? ''
    const head = b.subarray(0, 64).toString('latin1').replace(/^\uFEFF/, '').trimStart()
    if (head.startsWith('#EXTM3U')) return 'hls'
    if (b[0] === 0x1a && b[1] === 0x45 && b[2] === 0xdf && b[3] === 0xa3) return /webm/i.test(type) ? 'webm' : 'mkv'
    if (b.subarray(4, 8).toString('latin1') === 'ftyp') return 'mp4'
    if (b.length >= 189 && b[0] === 0x47 && b[188] === 0x47) return 'ts'
    if (/mpegurl/i.test(type)) return 'hls'
    if (/^video\/(mp4|quicktime)/i.test(type)) return 'mp4'
    if (/matroska/i.test(type)) return 'mkv'
    return null
  } catch { return null }
}

export async function addonStreams(pageUrl: string, credential?: string): Promise<ResolvedStream[]> {
  const route = parseAddonRoute(pageUrl)
  if (!route) return []
  const prefixes = await idPrefixes(route.root)
  const useTmdb = !!prefixes && !prefixes.includes('tt') && prefixes.includes('tmdb:')
  const base = useTmdb ? `tmdb:${route.tmdbId}` : await imdbFor(route.type, route.tmdbId, credential)
  if (!base) return []
  const id = route.type === 'tv' ? `${base}:${route.season}:${route.episode}` : base
  const res = await fetch(`${route.root}/stream/${route.type === 'tv' ? 'series' : 'movie'}/${encodeURIComponent(id)}.json`, {
    headers: { 'User-Agent': DESKTOP_UA, Accept: 'application/json' }, signal: AbortSignal.timeout(45_000)
  })
  if (!res.ok) throw new Error(`Addon returned HTTP ${res.status}`)
  const list = ((await res.json()) as { streams?: AddonStream[] }).streams ?? []

  const direct = list.filter(s => typeof s.url === 'string' && /^https?:\/\//i.test(s.url)).slice(0, 30)
  const checked = await Promise.all(direct.map(async s => {
    const headers: Record<string, string> = {}
    for (const [k, v] of Object.entries(s.behaviorHints?.proxyHeaders?.request ?? {})) if (!HOP.has(k.toLowerCase())) headers[k] = String(v)
    const format = await probeFormat(s.url!, headers)
    if (!format) return null
    const detail = (s.title ?? s.description ?? s.behaviorHints?.filename ?? '').split('\n').map(l => l.trim()).filter(Boolean)[0] ?? ''
    const label = [s.name?.replace(/\s+/g, ' ').trim(), detail].filter(Boolean).join(' · ') || 'Stream'
    const quality = /\b(2160p|4k|1440p|1080p|720p|480p|360p)\b/i.exec(`${s.name ?? ''} ${s.title ?? ''} ${s.description ?? ''}`)?.[1]?.toLowerCase()
    const stream: ResolvedStream = {
      id: s.url!, name: (label + (format === 'mkv' ? ' · MKV' : '')).slice(0, 140), url: s.url!,
      requestHeaders: headers, quality, subtitles: [], format
    }
    return stream
  }))
  // HLS / MP4 play reliably; MKV only for some codecs, so try it last.
  return checked.filter((s): s is ResolvedStream => !!s).sort((a, b) => Number(a.format === 'mkv') - Number(b.format === 'mkv'))
}
