// Portable-exe updater (ported from the v1 app). Reads version.json from the
// public repo, downloads the new exe and swaps it in after we quit.
import { app } from 'electron'
import { createWriteStream, writeFileSync } from 'node:fs'
import { get } from 'node:https'
import { basename, dirname, join } from 'node:path'
import { spawn } from 'node:child_process'
import type { UpdateCheckResult } from '@shared/types'

const MANIFEST_URL = 'https://raw.githubusercontent.com/huzaifah1530-bot/VixSrc-Public/main/version.json'
const EXE_BASE_URL = 'https://raw.githubusercontent.com/huzaifah1530-bot/VixSrc-Public/main/'
const UA = { 'User-Agent': 'Vela-Updater' }

function compareVersions(a: string, b: string) {
  const pa = a.split('.').map(n => parseInt(n, 10) || 0)
  const pb = b.split('.').map(n => parseInt(n, 10) || 0)
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] || 0) - (pb[i] || 0)
    if (d) return d > 0 ? 1 : -1
  }
  return 0
}

function download(url: string, dest: string, onProgress?: (f: number) => void): Promise<string> {
  return new Promise((resolve, reject) => {
    get(url, { headers: UA }, res => {
      if (res.statusCode && res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        res.resume()
        download(res.headers.location, dest, onProgress).then(resolve, reject)
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
  const res = await fetch(MANIFEST_URL, { headers: UA, signal: AbortSignal.timeout(15_000) })
  if (!res.ok) throw new Error('Update check failed: HTTP ' + res.status)
  const manifest = (await res.json()) as { version?: string; exe?: string; notes?: string }
  const latest = String(manifest.version ?? '').trim()
  if (!latest) throw new Error('Update manifest is missing a version.')
  const current = app.getVersion()
  return {
    updateAvailable: compareVersions(latest, current) > 0,
    currentVersion: current,
    latestVersion: latest,
    exeName: manifest.exe || 'Vela.exe',
    notes: manifest.notes || ''
  }
}

export async function applyUpdate(exeName: string, onProgress: (f: number) => void) {
  if (!/^[\w .-]+\.exe$/i.test(exeName)) throw new Error('Invalid update file name.')
  const downloaded = await download(EXE_BASE_URL + encodeURIComponent(exeName), join(app.getPath('temp'), `Vela-update-${Date.now()}.exe`), onProgress)
  // A portable exe can't overwrite itself while running; a detached script
  // waits for us to exit, swaps the file and relaunches.
  const current = process.env.PORTABLE_EXECUTABLE_FILE || app.getPath('exe')
  const name = basename(current)
  const backup = join(dirname(current), name + '.old')
  const script = join(app.getPath('temp'), `vela-update-${Date.now()}.bat`)
  writeFileSync(script, [
    '@echo off', ':waitloop',
    `tasklist /FI "IMAGENAME eq ${name}" 2>NUL | find /I "${name}" >NUL`,
    'if not errorlevel 1 (', '  timeout /t 1 /nobreak >NUL', '  goto waitloop', ')',
    `if exist "${backup}" del /f /q "${backup}"`,
    `if exist "${current}" rename "${current}" "${name}.old"`,
    `move /y "${downloaded}" "${current}"`,
    `if exist "${backup}" del /f /q "${backup}"`,
    `start "" "${current}"`,
    'del "%~f0"'
  ].join('\r\n'), 'utf8')
  spawn('cmd.exe', ['/c', script], { detached: true, stdio: 'ignore', windowsHide: true }).unref()
  app.quit()
}
