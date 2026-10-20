// Update checks against the public releases repo. Every launch we read the
// latest GitHub release; if its tag is newer than this build, the user can
// download and run the Setup wizard. If that fails we open the release page.
import { app, shell } from 'electron'
import { createWriteStream } from 'node:fs'
import { get } from 'node:https'
import { join } from 'node:path'
import { spawn } from 'node:child_process'
import type { UpdateCheckResult } from '@shared/types'

const REPO = 'huzaifah1530-bot/Vela'
const LATEST_URL = `https://api.github.com/repos/${REPO}/releases/latest`
export const RELEASES_PAGE = `https://github.com/${REPO}/releases/latest`
const DOWNLOAD_PREFIX = `https://github.com/${REPO}/releases/download/`
const UA = { 'User-Agent': 'Vela-Updater', Accept: 'application/vnd.github+json' }

/** Compares dotted versions, ignoring a leading "v" and any "-beta" suffix. */
export function compareVersions(a: string, b: string) {
  const parse = (v: string) => v.trim().replace(/^v/i, '').split(/[-+]/)[0].split('.').map(n => parseInt(n, 10) || 0)
  const pa = parse(a), pb = parse(b)
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] || 0) - (pb[i] || 0)
    if (d) return d > 0 ? 1 : -1
  }
  return 0
}

function download(url: string, dest: string, onProgress?: (f: number) => void, hops = 0): Promise<string> {
  return new Promise((resolve, reject) => {
    if (hops > 5) { reject(new Error('Too many redirects')); return }
    get(url, { headers: { 'User-Agent': UA['User-Agent'] } }, res => {
      if (res.statusCode && res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        res.resume()
        const next = new URL(res.headers.location, url).toString()
        if (!next.startsWith('https://')) { reject(new Error('Insecure redirect')); return }
        download(next, dest, onProgress, hops + 1).then(resolve, reject)
        return
      }
      if (res.statusCode !== 200) { res.resume(); reject(new Error('Download failed: HTTP ' + res.statusCode)); return }
      const total = parseInt(res.headers['content-length'] || '0', 10)
      let done = 0
      const file = createWriteStream(dest)
      res.on('data', c => { done += c.length; if (total && onProgress) onProgress(done / total) })
      res.pipe(file)
      file.on('finish', () => file.close(() => resolve(dest)))
      file.on('error', reject)
    }).on('error', reject)
  })
}

export async function checkForUpdate(): Promise<UpdateCheckResult> {
  const res = await fetch(LATEST_URL, { headers: UA, signal: AbortSignal.timeout(15_000) })
  if (!res.ok) throw new Error('Update check failed: HTTP ' + res.status)
  const release = (await res.json()) as {
    tag_name?: string; html_url?: string; body?: string
    assets?: { name: string; browser_download_url: string }[]
  }
  const latest = String(release.tag_name ?? '').trim().replace(/^v/i, '')
  if (!latest) throw new Error('The latest release has no version tag.')
  const current = app.getVersion()
  const setup = release.assets?.find(a => /setup.*\.exe$/i.test(a.name)) ?? release.assets?.find(a => /\.exe$/i.test(a.name))
  return {
    updateAvailable: compareVersions(latest, current) > 0,
    currentVersion: current,
    latestVersion: latest,
    downloadUrl: setup?.browser_download_url,
    releaseUrl: release.html_url || RELEASES_PAGE,
    notes: (release.body || '').trim().slice(0, 400)
  }
}

/**
 * Downloads the Setup wizard and launches it, then quits so the installer can
 * replace our files. Any failure opens the release page instead.
 */
export async function applyUpdate(downloadUrl: string | undefined, releaseUrl: string | undefined, onProgress: (f: number) => void) {
  const fallback = releaseUrl?.startsWith(`https://github.com/${REPO}/`) ? releaseUrl : RELEASES_PAGE
  try {
    if (!downloadUrl || !downloadUrl.startsWith(DOWNLOAD_PREFIX) || !/\.exe$/i.test(downloadUrl)) throw new Error('No installer in this release.')
    const dest = join(app.getPath('temp'), `Vela-Setup-${Date.now()}.exe`)
    await download(downloadUrl, dest, onProgress)
    await new Promise<void>((resolve, reject) => {
      const child = spawn(dest, [], { detached: true, stdio: 'ignore' })
      child.once('error', reject)
      child.once('spawn', () => { child.unref(); resolve() })
    })
    // Give the wizard a moment to appear before we close.
    setTimeout(() => app.quit(), 800)
  } catch (err) {
    shell.openExternal(fallback)
    throw new Error(`${(err as Error).message} Opened the download page instead.`)
  }
}
