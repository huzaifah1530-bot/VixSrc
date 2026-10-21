// Nuvio providers are stored as ordinary servers whose base is the provider
// script's URL, e.g. https://raw.githubusercontent.com/…/providers/xprime.js.
// The app builds <base>/movie/<id> like any server; the resolver recognises
// the `.js/` route and runs the bundled copy of that provider instead.
import { NUVIO_PROVIDERS, type NuvioProvider } from './nuvioProviders'

const ROUTE = /\/providers\/([\w.-]+\.js)(?:\/(movie|tv)\/([^/?#]+)(?:\/(\d+)\/(\d+))?)?\/?$/i

export function isNuvioUrl(url: string | null | undefined): boolean {
  if (!url) return false
  try { return ROUTE.test(new URL(url).pathname) } catch { return false }
}

export interface NuvioRoute { provider: NuvioProvider; type: 'movie' | 'tv'; tmdbId: string; season: number | null; episode: number | null }

export function parseNuvioRoute(url: string): NuvioRoute | null {
  let m: RegExpExecArray | null
  try { m = ROUTE.exec(new URL(url).pathname) } catch { return null }
  if (!m || !m[2] || !m[3]) return null
  const provider = NUVIO_PROVIDERS.find(p => p.file.toLowerCase() === m![1].toLowerCase())
  if (!provider) return null
  const type = m[2].toLowerCase() as 'movie' | 'tv'
  if (type === 'tv' && (!m[4] || !m[5])) return null
  return { provider, type, tmdbId: decodeURIComponent(m[3]), season: m[4] ? Number(m[4]) : null, episode: m[5] ? Number(m[5]) : null }
}

/** Servers from the Nuvio manifest, in manifest order. */
export function nuvioServers(makeId: () => string) {
  return NUVIO_PROVIDERS.map(p => ({ id: makeId(), name: p.name, base: p.base }))
}
