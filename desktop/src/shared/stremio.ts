// Stremio stream addons (e.g. NebulaStreams) are stored as ordinary servers
// whose base is the addon's manifest URL: …/manifest.json. The app builds
// <base>/movie/<tmdbId> or /tv/<tmdbId>/<s>/<e> like any server; resolvers
// recognise the `manifest.json/` route and query the addon's /stream API.

export const NEBULA_STREAMS = { name: 'NebulaStreams', base: 'https://nebula.work.gd/manifest.json' }

const ROUTE = /^(.*)\/manifest\.json\/(movie|tv)\/([^/?#]+)(?:\/(\d+)\/(\d+))?\/?$/i

export function isAddonUrl(url: string | null | undefined): boolean {
  if (!url) return false
  try { const u = new URL(url); return ROUTE.test(u.origin + u.pathname) } catch { return false }
}

export interface AddonRoute {
  /** Addon root, without /manifest.json. */
  root: string
  type: 'movie' | 'tv'
  tmdbId: string
  season: number | null
  episode: number | null
}

export function parseAddonRoute(url: string): AddonRoute | null {
  let u: URL
  try { u = new URL(url) } catch { return null }
  const m = ROUTE.exec(u.origin + u.pathname)
  if (!m) return null
  const type = m[2].toLowerCase() as 'movie' | 'tv'
  if (type === 'tv' && (!m[4] || !m[5])) return null
  return { root: m[1], type, tmdbId: decodeURIComponent(m[3]), season: m[4] ? Number(m[4]) : null, episode: m[5] ? Number(m[5]) : null }
}

/** A server is an addon when its base is a manifest URL. */
export const isAddonBase = (base: string) => /\/manifest\.json\/?$/i.test(base.trim())

/** Old Nuvio provider servers (…/nuvio-providers/…/providers/<id>.js). */
export const isRetiredNuvio = (base: string) => /\/nuvio-providers\/.*\/providers\/[\w.-]+\.js\/?$/i.test(base)
