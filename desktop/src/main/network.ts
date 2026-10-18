// Session wiring. Two sessions:
//  • default  — the Vela UI. Strict; only gets Referer/UA injection for the
//               stream currently playing in the native player, plus CORS
//               headers so hls.js can read cross-origin playlists.
//  • embed    — third-party web players (<webview partition="persist:embed">).
//               Adblock, frame-header stripping, popup blocking and an
//               m3u8 sniffer that hands streams to the native player.
import { session, shell, type Session, type WebContents } from 'electron'
import { ElectronBlocker } from '@ghostery/adblocker-electron'
import fetch from 'cross-fetch'
import { DESKTOP_UA } from './http'

export const EMBED_PARTITION = 'persist:embed'

let playbackHeaders: Record<string, string> | null = null
export function setPlaybackHeaders(h: Record<string, string> | null) { playbackHeaders = h }

const isTmdb = (url: string) => {
  try { const h = new URL(url).hostname; return /(^|\.)themoviedb\.org$|(^|\.)tmdb\.org$/.test(h) } catch { return false }
}
const isLocal = (url: string) => url.startsWith('file:') || url.startsWith('devtools:') || /^https?:\/\/(localhost|127\.0\.0\.1)/.test(url)

export function configureDefaultSession(mainContentsId: () => number | null) {
  const s = session.defaultSession

  s.webRequest.onBeforeSendHeaders((details, cb) => {
    const headers = { ...details.requestHeaders }
    const fromApp = details.webContentsId === mainContentsId()
    if (fromApp && playbackHeaders && !isLocal(details.url) && !isTmdb(details.url) &&
        ['xhr', 'media', 'other'].includes(details.resourceType)) {
      for (const [k, v] of Object.entries(playbackHeaders)) headers[k] = v
    }
    cb({ requestHeaders: headers })
  })

  s.webRequest.onHeadersReceived((details, cb) => {
    const fromApp = details.webContentsId === mainContentsId()
    if (!fromApp || isLocal(details.url) || !['xhr', 'media', 'other'].includes(details.resourceType)) {
      cb({}); return
    }
    const headers = { ...details.responseHeaders }
    for (const k of Object.keys(headers)) if (k.toLowerCase().startsWith('access-control-')) delete headers[k]
    headers['Access-Control-Allow-Origin'] = ['*']
    headers['Access-Control-Allow-Headers'] = ['*']
    cb({ responseHeaders: headers })
  })
}

export async function configureEmbedSession(onSniff: (url: string, referer?: string) => void): Promise<Session> {
  const s = session.fromPartition(EMBED_PARTITION)
  s.setUserAgent(DESKTOP_UA)

  try {
    const blocker = await ElectronBlocker.fromPrebuiltAdsAndTracking(fetch)
    blocker.enableBlockingInSession(s)
  } catch (err) {
    console.error('Adblocker failed to load:', err)
  }

  const referers = new Map<string, string>()
  s.webRequest.onBeforeSendHeaders({ urls: ['*://*/*'] }, (details, cb) => {
    const ref = details.requestHeaders.Referer ?? details.requestHeaders.referer
    if (/\.m3u8(\?|$)/i.test(details.url)) {
      if (ref) referers.set(details.url, ref)
      onSniff(details.url, ref)
    }
    cb({ requestHeaders: details.requestHeaders })
  })

  s.webRequest.onHeadersReceived((details, cb) => {
    const headers = { ...details.responseHeaders }
    for (const k of Object.keys(headers)) {
      const l = k.toLowerCase()
      if (l === 'x-frame-options' || l === 'content-security-policy') delete headers[k]
    }
    cb({ responseHeaders: headers })
  })
  return s
}

/** Popup policy for every web contents: TMDB opens in the browser, rest denied. */
export function lockDownContents(contents: WebContents) {
  contents.setWindowOpenHandler(({ url }) => {
    if (isTmdb(url)) shell.openExternal(url)
    return { action: 'deny' }
  })
  contents.on('will-attach-webview', (_e, prefs, params) => {
    // Only our embed partition, never with node or a preload.
    delete (prefs as Record<string, unknown>).preload
    prefs.nodeIntegration = false
    prefs.contextIsolation = true
    prefs.sandbox = true
    params.partition = EMBED_PARTITION
  })
  contents.on('will-navigate', (e, url) => {
    if (contents.getType() === 'window' && !isLocal(url)) e.preventDefault()
  })
}
