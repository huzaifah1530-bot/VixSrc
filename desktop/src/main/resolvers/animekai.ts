// Port of iOS AnimeKaiClient (itself a port of the Mangayomi `anikoto.js`
// extension). Browses the AnimeKai / AniKoto catalogue and resolves episodes
// down to HLS playlists, split into Sub/Dub × quality sources.
import { createDecipheriv, createHmac } from 'node:crypto'
import type { AnimeDetails, AnimeEpisode, AnimeShow, ExternalSubtitle, ResolvedStream, SkipSegment } from '@shared/types'
import { normType, parseAired, streamSegments, type AnimeIdentity } from '@shared/introSkip'
import { DESKTOP_UA as UA, allMatches, firstMatch, getText } from '../http'

// Constants MegaPlay's own player ships in the clear.
const ENC_KEY = 'i?LMTAx0Q6,:}50U'
const ENC_IV = "W0;27ToaUpl_P%'c"
const CDN_SECRET = 'MpCdnT0k3n!9f2K#xQ7vL5mR8wN1pY4s'
const TOKEN_TTL = 21_600
const SERVER_ORDER = ['vidplay', 'hd', 'vidstream', 'vidcloud']

const clean = (base: string) => base.replace(/\/+$/, '')
const xhr = (referer: string) => ({
  'User-Agent': UA,
  Referer: referer,
  'X-Requested-With': 'XMLHttpRequest',
  Accept: 'application/json, text/javascript, */*; q=0.01'
})
const page = (base: string) => ({ 'User-Agent': UA, Referer: base + '/' })

// ── Catalogue ─────────────────────────────────────────────────────────
export async function list(base: string, path: string): Promise<AnimeShow[]> {
  base = clean(base)
  return parseCards(await getText(base + path, page(base)))
}

export async function search(base: string, query: string): Promise<AnimeShow[]> {
  base = clean(base)
  return parseCards(await getText(`${base}/filter?keyword=${encodeURIComponent(query)}`, page(base)))
}

export async function findSlug(base: string, title: string): Promise<string | null> {
  const results = await search(base, title)
  const target = normalize(title)
  const exact = results.find(r => normalize(r.title) === target || normalize(r.japaneseTitle) === target)
  if (exact) return exact.slug
  let best: { slug: string; score: number } | null = null
  for (const r of results) {
    const score = Math.max(similarity(target, normalize(r.title)), similarity(target, normalize(r.japaneseTitle)))
    if (score >= 0.6 && (!best || score > best.score)) best = { slug: r.slug, score }
  }
  return best?.slug ?? null
}

export async function details(base: string, slug: string): Promise<AnimeDetails> {
  base = clean(base)
  const watchUrl = `${base}/watch/${slug}`
  const html = await getText(watchUrl, page(base))

  const heading = decode(stripTags(firstMatch(/<h1\b[^>]*>([\s\S]*?)<\/h1>/i, html) ?? ''))
  const japanese = decode(firstMatch(/<h1\b[^>]*data-jp="([^"]*)"/i, html) ?? '')
  const poster = firstMatch(/itemprop="image"\s+src="([^"]+)"/i, html) ?? firstMatch(/og:image"\s+content="([^"]+)"/i, html) ?? ''
  const synopsis = decode(stripTags(firstMatch(/class="synopsis[\s\S]*?class="content">([\s\S]*?)<\/div>/i, html) ?? ''))
  const kind = firstMatch(/<label>\s*(TV|MOVIE|OVA|ONA|SPECIAL|MUSIC)\s*<\/label>/i, html) ?? ''
  const animeId = firstMatch(/id="watch-main"[^>]*data-id="(\d+)"/i, html) ?? firstMatch(/data-id="(\d+)"[^>]*id="watch-main"/i, html)
  if (!animeId) throw new Error("Couldn't find this title")

  const listHtml = resultHtml(await getText(`${base}/ajax/episode/list/${animeId}?vrf=`, xhr(watchUrl + '/')))
  const episodes: AnimeEpisode[] = []
  for (const anchor of allMatches('<a\\b[^>]*\\bdata-num="[^"]*"[^>]*>[\\s\\S]*?</a>', listHtml)) {
    const tag = firstMatch(/^<a\b[^>]*>/i, anchor, 0) ?? ''
    const num = attr('data-num', tag), ids = attr('data-ids', tag)
    if (!num || !ids || episodes.some(e => e.number === num)) continue
    let title = decode(stripTags(firstMatch(/d-title[^>]*>([\s\S]*?)<\/span>/i, anchor) ?? ''))
    if (!title || title.toLowerCase() === `episode ${num}`) title = `Episode ${num}`
    episodes.push({ number: num, title, ids, hasSub: attr('data-sub', tag) === '1', hasDub: attr('data-dub', tag) === '1' })
  }
  return {
    show: {
      slug, title: heading || slug, japaneseTitle: japanese, posterURL: poster, kind,
      subCount: episodes.filter(e => e.hasSub).length, dubCount: episodes.filter(e => e.hasDub).length
    },
    description: synopsis,
    episodes,
    identity: pageIdentity(html, heading, japanese)
  }
}

/** Type / first air date / episode total / titles from the watch page meta. */
export function pageIdentity(html: string, heading: string, japanese: string): AnimeIdentity {
  const meta = (label: string) => {
    const raw = firstMatch(new RegExp(`${label}:\\s*<span[^>]*>([\\s\\S]*?)</span>`, 'i'), html)
    return raw ? decode(stripTags(raw)) : ''
  }
  const names = decode(stripTags(firstMatch(/class="names[^"]*"[^>]*>([\s\S]*?)<\/div>/i, html) ?? ''))
  const titles = [heading, japanese, ...names.split(';')].map(t => t.trim()).filter(Boolean)
  const episodes = Number(meta('Episodes'))
  return {
    titles: [...new Set(titles)],
    type: normType(meta('Type')),
    aired: parseAired(meta('Aired')),
    episodes: Number.isInteger(episodes) && episodes > 0 ? episodes : null
  }
}

function parseCards(html: string): AnimeShow[] {
  const out: AnimeShow[] = []
  const chunks = [...html.split('class="item ').slice(1), ...html.split('class="item"').slice(1)]
  for (const chunk of chunks) {
    const tag = firstMatch(/<a\b[^>]*\bd-title\b[^>]*>[\s\S]*?<\/a>/i, chunk, 0)
    const href = tag ? attr('href', tag) : null
    const slug = href ? firstMatch(/\/(?:watch|anime)\/([^/?#"]+)/i, href) : null
    if (!tag || !slug || out.some(s => s.slug === slug)) continue
    const name = decode(stripTags(firstMatch(/>([\s\S]*?)<\/a>/i, tag) ?? ''))
    if (!name) continue
    const sub = firstMatch(/ep-status sub"><span>\s*(\d+)/i, chunk)
    const dub = firstMatch(/ep-status dub"><span>\s*(\d+)/i, chunk)
    out.push({
      slug, title: name,
      japaneseTitle: decode(attr('data-jp', tag) ?? ''),
      posterURL: firstMatch(/<img[^>]*\bsrc="([^"]+)"/i, chunk) ?? '',
      kind: (firstMatch(/<div class="right">\s*([^<]+?)\s*<\/div>/i, chunk) ?? '').trim(),
      subCount: sub ? Number(sub) : undefined,
      dubCount: dub ? Number(dub) : undefined
    })
  }
  return out
}

// ── Streams ───────────────────────────────────────────────────────────
interface ServerEntry { linkId: string; name: string }

export async function streams(base: string, episodeIds: string): Promise<ResolvedStream[]> {
  base = clean(base)
  const groups = await serverGroups(base, episodeIds)
  const [sub, dub] = await Promise.all([resolveTrack(base, groups.sub, 'Sub'), resolveTrack(base, groups.dub, 'Dub')])
  const all = [...sub, ...dub]
  if (!all.length) throw new Error('No playable streams found')
  return all
}

async function serverGroups(base: string, ids: string) {
  const html = resultHtml(await getText(`${base}/ajax/server/list?servers=${encodeURIComponent(ids)}`, xhr(base + '/')))
  const marks = Array.from(html.matchAll(/data-type="([a-z]+)"/g))
  const sections = marks.length
    ? marks.map((m, i) => ({ type: m[1], body: html.slice(m.index!, i + 1 < marks.length ? marks[i + 1].index! : html.length) }))
    : [{ type: 'sub', body: html }]
  const order = (n: string) => { const i = SERVER_ORDER.findIndex(p => n.toLowerCase().startsWith(p)); return i < 0 ? SERVER_ORDER.length : i }
  const entries = (body: string): ServerEntry[] =>
    allMatches('<li\\b[^>]*data-link-id="[^"]+"[^>]*>[\\s\\S]*?</li>', body)
      .map(li => ({ linkId: attr('data-link-id', li) ?? '', name: decode(stripTags(firstMatch(/>([\s\S]*?)<\/li>/i, li) ?? '')) }))
      .filter(e => e.linkId)
      .sort((a, b) => order(a.name) - order(b.name))
  // Soft subs first (their VTT tracks render natively), then hard subs.
  const sub = ['sub', 'softsub', 'hsub'].flatMap(t => sections.filter(s => s.type === t).flatMap(s => entries(s.body)))
  const dub = sections.filter(s => s.type === 'dub').flatMap(s => entries(s.body))
  return { sub, dub }
}

async function resolveTrack(base: string, servers: ServerEntry[], audio: 'Sub' | 'Dub'): Promise<ResolvedStream[]> {
  for (const s of servers.slice(0, 6)) {
    try {
      const found = await resolveServer(base, s.linkId, audio)
      if (found.length) return found
    } catch { /* next server */ }
  }
  return []
}

async function resolveServer(base: string, linkId: string, audio: 'Sub' | 'Dub'): Promise<ResolvedStream[]> {
  const json = JSON.parse(await getText(`${base}/ajax/server?get=${encodeURIComponent(linkId)}`, xhr(base + '/')))
  const r = json?.result
  const embed: string = typeof r === 'string' ? r : (r?.url ?? r?.link ?? '')
  if (!embed) return []
  const streamId = firstMatch(/\/stream\/s-\d+\/(\d+)\/(?:sub|dub)/i, embed)
  if (streamId) return megaPlay(embed, streamId, base, audio)
  if (embed.includes('vidtube.site/stream/')) return vidTube(embed, base, audio)
  if (embed.includes('.m3u8')) return variants(embed, base + '/', audio, [])
  return []
}

async function megaPlay(embed: string, fallbackId: string, base: string, audio: 'Sub' | 'Dub') {
  const u = new URL(embed)
  const host = `${u.protocol}//${u.host}`
  let id = fallbackId
  try {
    const html = await getText(embed, page(base))
    id = firstMatch(/data-id="(\d+)"/i, html) ?? firstMatch(/<title>File (\d+)/i, html) ?? id
  } catch { /* keep fallback */ }
  const body = await getText(`${host}/stream/getSources?id=${id}`, { ...xhr(host + '/'), Accept: 'application/json' })
  return fromSources(JSON.parse(body), host + '/', audio)
}

async function vidTube(embed: string, base: string, audio: 'Sub' | 'Dub') {
  const html = await getText(embed, page(base))
  const fileId = firstMatch(/getSourcesNew\?id=(\d+)/i, html) ?? firstMatch(/<title>File (\d+)/i, html)
  if (!fileId) return []
  const type = firstMatch(/\/(sub|dub)(?:[?#]|$)/i, embed) ?? 'sub'
  const body = await getText(`https://vidtube.site/stream/getSourcesNew?id=${fileId}&type=${type}`, xhr('https://vidtube.site/'))
  return fromSources(JSON.parse(body), 'https://vidtube.site/', audio)
}

async function fromSources(json: Record<string, unknown>, referer: string, audio: 'Sub' | 'Dub') {
  let file = playlistUrl(json.sources) ?? ''
  if (!file && typeof json.enc === 'string') file = decryptSources(json.enc) ?? ''
  if (!file) return []
  const tracks: ExternalSubtitle[] = (Array.isArray(json.tracks) ? json.tracks : [])
    .filter((t: any) => t?.kind !== 'thumbnails' && typeof t?.file === 'string')
    .map((t: any) => ({ label: t.label ?? 'Subtitles', url: t.file, referer }))
  // MegaPlay ships the episode's opening/ending; 0/0 means none.
  return variants(signCdnUrl(file), referer, audio, tracks, streamSegments(json))
}

function playlistUrl(v: unknown): string | null {
  if (typeof v === 'string' && v) return v
  if (Array.isArray(v) && v.length) return playlistUrl(v[0])
  if (v && typeof v === 'object') {
    const o = v as Record<string, unknown>
    return (o.file as string) ?? (o.url as string) ?? playlistUrl(o.sources)
  }
  return null
}

/** Splits a master playlist into Auto + one source per resolution. */
async function variants(master: string, referer: string, audio: 'Sub' | 'Dub', subtitles: ExternalSubtitle[], segments: SkipSegment[] = []): Promise<ResolvedStream[]> {
  const headers = { 'User-Agent': UA, Referer: referer }
  const body = await getText(master, headers)
  if (!body.includes('#EXTM3U')) return []
  const make = (url: string, quality: string): ResolvedStream => ({
    id: `${audio}|${url}`, name: `${quality} · ${audio}`, url, requestHeaders: headers, audio, quality, subtitles, segments
  })
  const out = [make(master, 'Auto')]
  if (!body.includes('#EXT-X-STREAM-INF')) return out
  const lines = body.split(/\r?\n/).map(l => l.trim())
  const levels: { h: number; url: string }[] = []
  lines.forEach((line, i) => {
    if (!line.startsWith('#EXT-X-STREAM-INF:')) return
    const h = Number(firstMatch(/RESOLUTION=\d+x(\d+)/i, line))
    const uri = lines.slice(i + 1).find(l => l && !l.startsWith('#'))
    if (!h || !uri || levels.some(l => l.h === h)) return
    levels.push({ h, url: new URL(uri, master).href })
  })
  return [...out, ...levels.sort((a, b) => b.h - a.h).map(l => make(l.url, `${l.h}p`))]
}

// ── MegaPlay crypto ───────────────────────────────────────────────────
function pad(s: string, len: number) {
  const b = Buffer.alloc(len)
  Buffer.from(s, 'utf8').copy(b, 0, 0, len)
  return b
}

function decryptSources(enc: string): string | null {
  try {
    let cipher = Buffer.from(enc.replace(/-/g, '+').replace(/_/g, '/').replace(/[^A-Za-z0-9+/]/g, ''), 'base64')
    cipher = cipher.subarray(0, cipher.length - (cipher.length % 16))
    if (!cipher.length) return null
    const d = createDecipheriv('aes-256-cbc', pad(ENC_KEY, 32), pad(ENC_IV, 16))
    d.setAutoPadding(false)
    let plain = Buffer.concat([d.update(cipher), d.final()])
    const p = plain[plain.length - 1]
    if (p >= 1 && p <= 16 && plain.subarray(plain.length - p).every(b => b === p)) plain = plain.subarray(0, plain.length - p)
    return playlistUrl(JSON.parse(plain.toString('utf8')))
  } catch {
    return null
  }
}

const b64url = (b: Buffer) => b.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')

/** CDN wants token=b64url("<expiry>|<id1>/<id2>").b64url(HMAC-SHA256). */
function signCdnUrl(url: string): string {
  if (/[?&]token=/.test(url)) return url
  const m = /\/([a-fA-F0-9]{32})\/([a-fA-F0-9]{32})\//.exec(url)
  if (!m) return url
  const message = `${Math.floor(Date.now() / 1000) + TOKEN_TTL}|${m[1].toLowerCase()}/${m[2].toLowerCase()}`
  const mac = createHmac('sha256', CDN_SECRET).update(message).digest()
  return `${url}${url.includes('?') ? '&' : '?'}token=${b64url(Buffer.from(message))}.${b64url(mac)}`
}

// ── Text helpers ──────────────────────────────────────────────────────
function resultHtml(body: string): string {
  try { const j = JSON.parse(body); if (typeof j?.result === 'string') return j.result } catch { /* raw html */ }
  return body
}
function attr(name: string, tag: string) {
  return firstMatch(new RegExp(`\\b${name.replace(/[-]/g, '\\-')}="([^"]*)"`, 'i'), tag)
}
function stripTags(html: string) {
  return html.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim()
}
function decode(text: string) {
  return text
    .replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&#39;/g, "'")
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&nbsp;/g, ' ')
    .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)))
}
function normalize(t: string) {
  return t.normalize('NFKD').replace(/[\u0300-\u036f]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim()
}
function similarity(a: string, b: string) {
  if (!a || !b) return 0
  if (a === b) return 1
  const ta = new Set(a.split(' ')), tb = new Set(b.split(' '))
  const inter = [...ta].filter(x => tb.has(x)).length
  const dice = (2 * inter) / (ta.size + tb.size)
  const contains = b.startsWith(a + ' ') || a.startsWith(b + ' ') ? 0.3 : 0
  return Math.min(0.99, dice + contains)
}
