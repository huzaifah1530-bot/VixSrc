import { app, BrowserWindow, dialog, ipcMain, Menu, shell, screen } from 'electron'
import { cpSync, existsSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import type { MenuCommand } from '@shared/types'
import { configureDefaultSession, configureEmbedSession, lockDownContents, setPlaybackHeaders } from './network'
import { resolveStreams } from './resolvers/streams'
import * as anime from './resolvers/animekai'
import { applyUpdate, checkForUpdate } from './updater'
import { getResponse, getText, DESKTOP_UA } from './http'
import { LinkServer } from './link/server'
import { embedControl, embedState } from './link/embedBridge'
import type { LinkEvent } from '@shared/link'
import { isAddonUrl } from '@shared/stremio'
import type { AnimeIdentity } from '@shared/introSkip'
import { aniSkip, introDbTv } from './skip'

const DEFAULT_TMDB_CREDENTIAL = 'ce5e1892fe2fdf9006a6b4dfabe1fea4'
const PROTOCOLS = ['vela', 'vixscr'] // vixscr:// kept so old links still open

app.setName('Vela')
// Dev-only: run against a throwaway profile (scripts/phone-sim.ts).
if (!app.isPackaged && process.env.VELA_USER_DATA) app.setPath('userData', process.env.VELA_USER_DATA)

// ── One-time migration from the v1 "VixScr" profile ───────────────────
// Both apps load from file://, so copying Local Storage makes the old
// vixsrc_live_* keys visible; the renderer converts them on first launch.
;(() => {
  try {
    const legacy = join(app.getPath('appData'), 'VixScr', 'Local Storage')
    const target = join(app.getPath('userData'), 'Local Storage')
    if (existsSync(legacy) && !existsSync(target)) cpSync(legacy, target, { recursive: true })
  } catch (err) { console.error('Migration skipped:', err) }
})()

let mainWindow: BrowserWindow | null = null
let settingsWindow: BrowserWindow | null = null
let pendingId: string | null = null
let link: LinkServer | null = null

/** Link events go to every window; messages/actions only to the main one. */
function emitLink(e: LinkEvent) {
  const mainOnly = e.type === 'message' || e.type === 'action' || e.type === 'connected' || e.type === 'paired'
  for (const w of [mainWindow, settingsWindow]) {
    if (!w || w.isDestroyed()) continue
    if (mainOnly && w !== mainWindow) { if (e.type !== 'paired') continue }
    w.webContents.send('link', e)
  }
  if (e.type === 'pair-request' && mainWindow) { if (mainWindow.isMinimized()) mainWindow.restore(); mainWindow.show(); mainWindow.focus() }
}

/** vela://party/<room>#<key> from a browser invite page. */
function extractParty(argv: string[]) {
  return argv.find(a => /^vela:\/\/party\/[A-Za-z0-9_-]{8,32}#[A-Za-z0-9_-]{43}$/i.test(a ?? '')) ?? null
}
let pendingParty: string | null = null
function sendParty(link: string | null) {
  if (!link) return
  if (mainWindow && !mainWindow.webContents.isLoading()) mainWindow.webContents.send('open-party', link)
  else pendingParty = link
}
// The renderer asks once its listeners are ready (avoids a startup race).
ipcMain.handle('party:pending', () => { const l = pendingParty; pendingParty = null; return l })

function extractId(argv: string[]) {
  for (const arg of argv) {
    const m = /^(?:vela|vixscr):\/\/(?:open\/)?(\d+)/i.exec(arg ?? '')
    if (m) return m[1]
    if (/^\d+$/.test(arg?.trim() ?? '')) return arg.trim()
  }
  return null
}
const launchArgs = (argv: string[]) => (app.isPackaged ? argv.slice(1) : argv.slice(2))

// ── Window state ──────────────────────────────────────────────────────
const statePath = () => join(app.getPath('userData'), 'window-state.json')
function loadBounds() {
  try {
    const s = JSON.parse(readFileSync(statePath(), 'utf8'))
    const visible = screen.getAllDisplays().some(d =>
      s.x >= d.bounds.x - 50 && s.y >= d.bounds.y - 50 && s.x < d.bounds.x + d.bounds.width && s.y < d.bounds.y + d.bounds.height)
    return visible ? s : { width: s.width, height: s.height, maximized: s.maximized }
  } catch { return { width: 1440, height: 900 } }
}
function saveBounds(win: BrowserWindow) {
  try { writeFileSync(statePath(), JSON.stringify({ ...win.getNormalBounds(), maximized: win.isMaximized() })) } catch { /* ignore */ }
}

function loadRenderer(win: BrowserWindow, hash = '') {
  if (!app.isPackaged && process.env.ELECTRON_RENDERER_URL) win.loadURL(process.env.ELECTRON_RENDERER_URL + (hash ? '#' + hash : ''))
  else win.loadFile(join(__dirname, '../renderer/index.html'), { hash })
}

const appIcon = app.isPackaged ? join(process.resourcesPath, 'icon.png') : join(__dirname, '../../resources/icon.png')

const secureWebPrefs = {
  preload: join(__dirname, '../preload/index.js'),
  contextIsolation: true,
  nodeIntegration: false,
  sandbox: false, // preload is bundled as CJS and uses ipcRenderer only
  webviewTag: true,
  spellcheck: false,
  additionalArguments: [`--vela-version=${app.getVersion()}`]
}

function createMainWindow() {
  const b = loadBounds()
  mainWindow = new BrowserWindow({
    x: b.x, y: b.y, width: b.width, height: b.height,
    minWidth: 960, minHeight: 600,
    frame: false,
    backgroundColor: '#000000',
    show: false,
    title: 'Vela',
    icon: appIcon,
    webPreferences: secureWebPrefs
  })
  if (b.maximized) mainWindow.maximize()
  mainWindow.once('ready-to-show', () => mainWindow?.show())
  mainWindow.on('close', () => mainWindow && saveBounds(mainWindow))
  mainWindow.on('maximize', () => mainWindow?.webContents.send('maximized', true))
  mainWindow.on('unmaximize', () => mainWindow?.webContents.send('maximized', false))
  mainWindow.on('closed', () => { mainWindow = null; settingsWindow?.close() })
  mainWindow.webContents.once('did-finish-load', () => {
    if (pendingId) { mainWindow?.webContents.send('open-tmdb-id', pendingId); pendingId = null }

  })
  loadRenderer(mainWindow)
}

function openSettings() {
  if (settingsWindow) { settingsWindow.focus(); return }
  settingsWindow = new BrowserWindow({
    width: 760, height: 620, minWidth: 640, minHeight: 480,
    parent: mainWindow ?? undefined,
    frame: false, backgroundColor: '#0a0a0a', show: false, title: 'Vela Settings',
    webPreferences: secureWebPrefs
  })
  settingsWindow.once('ready-to-show', () => settingsWindow?.show())
  settingsWindow.on('closed', () => { settingsWindow = null })
  loadRenderer(settingsWindow, 'settings')
}

// ── App menu (shown from the toolbar; accelerators handled in renderer) ─
function send(cmd: MenuCommand) { mainWindow?.webContents.send('menu', cmd); if (cmd !== 'settings') mainWindow?.focus() }
function buildMenu() {
  const item = (label: string, cmd: MenuCommand, accelerator?: string) => ({ label, accelerator, registerAccelerator: false, click: () => (cmd === 'settings' ? openSettings() : send(cmd)) })
  return Menu.buildFromTemplate([
    { label: 'Vela', submenu: [item('About Vela', 'about'), item('Check for Updates…', 'check-updates'), { type: 'separator' }, item('Settings…', 'settings', 'Ctrl+,'), { type: 'separator' }, { label: 'Quit Vela', accelerator: 'Ctrl+Q', click: () => app.quit() }] },
    { label: 'File', submenu: [item('Join Watch Party…', 'join-party', 'Ctrl+J'), { type: 'separator' }, item('Export Backup…', 'export', 'Ctrl+E'), item('Import Backup…', 'import', 'Ctrl+O')] },
    { label: 'View', submenu: [item('Home', 'home', 'Ctrl+1'), item('Anime', 'anime', 'Ctrl+2'), item('Favourites', 'favorites', 'Ctrl+3'), { type: 'separator' }, item('Search', 'search', 'Ctrl+F'), item('Toggle Sidebar', 'toggle-sidebar', 'Ctrl+\\'), item('Refresh', 'refresh', 'Ctrl+R'), { type: 'separator' }, item('Back', 'back', 'Alt+Left'), item('Forward', 'forward', 'Alt+Right')] },
    { label: 'Playback', submenu: [item('Play / Pause', 'play-pause', 'Space'), item('Full Screen', 'fullscreen', 'F')] },
    { label: 'Help', submenu: [{ label: 'TMDB', click: () => shell.openExternal('https://www.themoviedb.org') }] }
  ])
}

// ── IPC ───────────────────────────────────────────────────────────────
function registerIpc() {
  ipcMain.handle('tmdb', async (_e, path: string, params: Record<string, string>, credential?: string) => {
    const key = (credential || DEFAULT_TMDB_CREDENTIAL).trim()
    const url = new URL('https://api.themoviedb.org/3' + path)
    for (const [k, v] of Object.entries(params ?? {})) if (v !== undefined && v !== '') url.searchParams.set(k, String(v))
    if (!url.searchParams.has('language')) url.searchParams.set('language', 'en-GB')
    const headers: Record<string, string> = { accept: 'application/json' }
    if (key.startsWith('eyJ') || key.length > 60) headers.Authorization = 'Bearer ' + key
    else url.searchParams.set('api_key', key)
    const res = await fetch(url, { headers, signal: AbortSignal.timeout(15_000) })
    const json = (await res.json().catch(() => ({}))) as { status_message?: string }
    if (!res.ok) throw new Error(`TMDB ${res.status}${json.status_message ? ' — ' + json.status_message : ''}`)
    return json
  })
  ipcMain.handle('resolve-streams', (_e, url: string) => resolveStreams(url))
  ipcMain.handle('anime:list', (_e, base: string, path: string) => anime.list(base, path))
  ipcMain.handle('anime:search', (_e, base: string, q: string) => anime.search(base, q))
  ipcMain.handle('anime:details', (_e, base: string, slug: string) => anime.details(base, slug))
  ipcMain.handle('anime:find-slug', (_e, base: string, title: string) => anime.findSlug(base, title))
  ipcMain.handle('anime:streams', (_e, base: string, ids: string) => anime.streams(base, ids))
  ipcMain.handle('skip:tv', (_e, tmdbId: unknown, season: unknown, episode: unknown, duration: unknown) =>
    introDbTv(String(tmdbId), Number(season), Number(episode), Number(duration) || 0))
  ipcMain.handle('skip:anime', (_e, identity: unknown, episode: unknown, duration: unknown) => {
    const i = identity as AnimeIdentity | null
    if (!i || !Array.isArray(i.titles) || typeof i.type !== 'string') return []
    const clean: AnimeIdentity = {
      titles: i.titles.filter((t): t is string => typeof t === 'string').slice(0, 10).map(t => t.slice(0, 200)),
      type: i.type.slice(0, 20), aired: typeof i.aired === 'string' ? i.aired.slice(0, 10) : null,
      episodes: Number.isInteger(i.episodes) ? i.episodes : null
    }
    return aniSkip(clean, String(episode).slice(0, 10), Number(duration) || 0)
  })
  ipcMain.handle('fetch-text', (_e, url: string, headers: Record<string, string>) => getText(url, { 'User-Agent': DESKTOP_UA, ...headers }))
  ipcMain.handle('check-server', async (_e, url: string) => {
    // Stremio addons: "reachable" means it returned a playable stream.
    if (isAddonUrl(url)) return (await resolveStreams(url).catch(() => [])).length > 0
    try { const r = await getResponse(url, { 'User-Agent': DESKTOP_UA }, 8000); r.body?.cancel().catch(() => {}); return true } catch { return false }
  })
  ipcMain.handle('playback-headers', (_e, h: Record<string, string> | null) => setPlaybackHeaders(h))

  ipcMain.on('win:minimize', e => BrowserWindow.fromWebContents(e.sender)?.minimize())
  ipcMain.on('win:toggle-maximize', e => { const w = BrowserWindow.fromWebContents(e.sender); if (w) w.isMaximized() ? w.unmaximize() : w.maximize() })
  ipcMain.on('win:close', e => BrowserWindow.fromWebContents(e.sender)?.close())
  ipcMain.on('win:fullscreen', (e, on: boolean) => BrowserWindow.fromWebContents(e.sender)?.setFullScreen(on))
  ipcMain.handle('win:is-maximized', e => BrowserWindow.fromWebContents(e.sender)?.isMaximized() ?? false)
  ipcMain.on('win:open-settings', () => openSettings())
  ipcMain.on('win:popup-menu', (e, x: number, y: number) => {
    const w = BrowserWindow.fromWebContents(e.sender)
    if (w) buildMenu().popup({ window: w, x: Math.round(x), y: Math.round(y) })
  })

  ipcMain.handle('update:check', async () => { try { return await checkForUpdate() } catch (err) { return { error: (err as Error).message } } })
  ipcMain.handle('update:apply', async (_e, url: unknown, page: unknown) => {
    const s = (v: unknown) => (typeof v === 'string' && v.length < 500 ? v : undefined)
    try { await applyUpdate(s(url), s(page), f => mainWindow?.webContents.send('update-download-progress', f)); return { ok: true } }
    catch (err) { return { ok: false, error: (err as Error).message } }
  })

  ipcMain.handle('save-file', async (e, name: string, contents: string) => {
    const w = BrowserWindow.fromWebContents(e.sender)
    const r = await dialog.showSaveDialog(w!, { defaultPath: name, filters: [{ name: 'Vela Backup', extensions: ['json'] }] })
    if (r.canceled || !r.filePath) return false
    writeFileSync(r.filePath, contents, 'utf8')
    return true
  })
  ipcMain.handle('open-file', async e => {
    const w = BrowserWindow.fromWebContents(e.sender)
    const r = await dialog.showOpenDialog(w!, { properties: ['openFile'], filters: [{ name: 'Vela Backup', extensions: ['json'] }] })
    return r.canceled || !r.filePaths[0] ? null : readFileSync(r.filePaths[0], 'utf8')
  })
  // ── Device link ─────────────────────────────────────────────────────
  const id = (v: unknown) => (typeof v === 'string' && v.length <= 64 ? v : '')
  ipcMain.handle('link:status', () => link?.status() ?? null)
  ipcMain.handle('link:start-pairing', () => link?.startPairing() ?? null)
  ipcMain.on('link:cancel-pairing', () => link?.cancelPairing())
  ipcMain.on('link:disconnect', (_e, d) => link?.disconnect(id(d)))
  ipcMain.on('link:forget', (_e, d) => link?.forget(id(d)))
  ipcMain.on('link:update', (_e, d, patch) => { if (patch && typeof patch === 'object') link?.update(id(d), patch) })
  ipcMain.on('link:send', (e, d, msg) => {
    // Only the main window speaks for the app (commands, state, sync).
    if (e.sender !== mainWindow?.webContents || !msg || typeof msg !== 'object') return
    link?.send(d === null ? null : id(d), msg)
  })
  ipcMain.on('link:action', (_e, action, d) => {
    if (['sync-now', 'fresh-copy-to', 'fresh-copy-from'].includes(action)) emitLink({ type: 'action', action, deviceId: id(d) })
  })
  ipcMain.handle('embed:state', () => embedState())
  ipcMain.handle('embed:control', (_e, action: string, value: number) => embedControl(String(action), Number(value)))
  ipcMain.on('win:show-main', () => { if (mainWindow) { if (mainWindow.isMinimized()) mainWindow.restore(); mainWindow.show() } })

  ipcMain.on('open-external', (_e, url: string) => { if (/^https:\/\//.test(url)) shell.openExternal(url) })
}

// ── Lifecycle ─────────────────────────────────────────────────────────
if (!app.requestSingleInstanceLock()) {
  app.quit()
} else {
  app.on('second-instance', (_e, argv) => {
    const id = extractId(launchArgs(argv))
    if (!mainWindow) return
    if (mainWindow.isMinimized()) mainWindow.restore()
    mainWindow.focus()
    if (id) mainWindow.webContents.send('open-tmdb-id', id)
    sendParty(extractParty(launchArgs(argv)))
  })

  app.whenReady().then(async () => {
    Menu.setApplicationMenu(null)
    app.on('web-contents-created', (_e, contents) => lockDownContents(contents))
    configureDefaultSession(() => mainWindow?.webContents.id ?? null)
    await configureEmbedSession((url, referer) => mainWindow?.webContents.send('embed-sniffed', { url, referer }))
    for (const p of PROTOCOLS) if (!app.isDefaultProtocolClient(p)) app.setAsDefaultProtocolClient(p)
    registerIpc()
    pendingId = extractId(launchArgs(process.argv))
    pendingParty = extractParty(launchArgs(process.argv))
    createMainWindow()
    link = new LinkServer(emitLink)
    link.start()
    // Dev-only hook for scripts/party-e2e.ts: join a party and report the
    // video element's state to a file twice a second.
    if (!app.isPackaged && process.env.VELA_PARTY_JOIN && process.env.VELA_PARTY_PROBE) {
      pendingParty = process.env.VELA_PARTY_JOIN
      setInterval(async () => {
        const s = await mainWindow?.webContents.executeJavaScript(`(() => { const v = document.querySelector('video'); return v ? { t: v.currentTime, paused: v.paused, rate: v.playbackRate, title: document.querySelector('.player-title')?.textContent } : null })()`).catch(() => null)
        writeFileSync(process.env.VELA_PARTY_PROBE!, JSON.stringify({ at: Date.now(), s }))
      }, 500)
    }
    // Dev-only hook for scripts/phone-sim.ts: publish a pairing link to a file.
    if (!app.isPackaged && process.env.VELA_LINK_TEST) {
      setTimeout(() => link?.startPairing().then(s => s.pairing && writeFileSync(process.env.VELA_LINK_TEST!, s.pairing.link)), 3000)
    }

    checkForUpdate()
      .then(r => mainWindow?.webContents.send('update-check-result', r))
      .catch(err => mainWindow?.webContents.send('update-check-result', { error: err.message }))
  })

  app.on('window-all-closed', () => app.quit())
  app.on('before-quit', () => link?.stop())
}
