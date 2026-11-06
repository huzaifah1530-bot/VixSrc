import { contextBridge, ipcRenderer } from 'electron'
import type { VelaApi } from '@shared/types'
import type { AccountApi } from '@shared/account'

const api: VelaApi & { account: AccountApi } = {
  account: {
    status: () => ipcRenderer.invoke('account:status'),
    call: (action, body) => ipcRenderer.invoke('account:call', action, body)
  },
  platform: process.platform,
  version: process.argv.find(a => a.startsWith('--vela-version='))?.split('=')[1] ?? '',
  tmdb: (path, params, credential) => ipcRenderer.invoke('tmdb', path, params, credential),
  resolveStreams: url => ipcRenderer.invoke('resolve-streams', url),
  anime: {
    list: (base, path) => ipcRenderer.invoke('anime:list', base, path),
    search: (base, q) => ipcRenderer.invoke('anime:search', base, q),
    details: (base, slug) => ipcRenderer.invoke('anime:details', base, slug),
    findSlug: (base, title) => ipcRenderer.invoke('anime:find-slug', base, title),
    streams: (base, ids) => ipcRenderer.invoke('anime:streams', base, ids)
  },
  skip: {
    tv: (tmdbId, imdbId, season, episode, duration) => ipcRenderer.invoke('skip:tv', tmdbId, imdbId, season, episode, duration),
    movie: (imdbId, duration) => ipcRenderer.invoke('skip:movie', imdbId, duration),
    anime: (identity, episode, duration, credential) => ipcRenderer.invoke('skip:anime', identity, episode, duration, credential)
  },
  fetchText: (url, headers) => ipcRenderer.invoke('fetch-text', url, headers),
  checkServer: url => ipcRenderer.invoke('check-server', url),
  setPlaybackHeaders: h => ipcRenderer.invoke('playback-headers', h),
  window: {
    minimize: () => ipcRenderer.send('win:minimize'),
    toggleMaximize: () => ipcRenderer.send('win:toggle-maximize'),
    close: () => ipcRenderer.send('win:close'),
    setFullScreen: on => ipcRenderer.send('win:fullscreen', on),
    isMaximized: () => ipcRenderer.invoke('win:is-maximized'),
    openSettings: () => ipcRenderer.send('win:open-settings'),
    popupMenu: (x, y) => ipcRenderer.send('win:popup-menu', x, y)
  },
  updater: {
    check: () => ipcRenderer.invoke('update:check'),
    apply: (url, page) => ipcRenderer.invoke('update:apply', url, page)
  },
  saveFile: (name, contents) => ipcRenderer.invoke('save-file', name, contents),
  openFile: () => ipcRenderer.invoke('open-file'),
  openExternal: url => ipcRenderer.send('open-external', url),
  link: {
    status: () => ipcRenderer.invoke('link:status'),
    startPairing: () => ipcRenderer.invoke('link:start-pairing'),
    cancelPairing: () => ipcRenderer.send('link:cancel-pairing'),
    disconnect: d => ipcRenderer.send('link:disconnect', d),
    forget: d => ipcRenderer.send('link:forget', d),
    update: (d, patch) => ipcRenderer.send('link:update', d, patch),
    send: (d, msg) => ipcRenderer.send('link:send', d, msg),
    action: (a, d) => ipcRenderer.send('link:action', a, d)
  },
  embed: {
    state: () => ipcRenderer.invoke('embed:state'),
    control: (a, v) => ipcRenderer.invoke('embed:control', a, v ?? 0)
  },
  showMainWindow: () => ipcRenderer.send('win:show-main'),
  pendingParty: () => ipcRenderer.invoke('party:pending'),
  on: ((channel: string, cb: (v: unknown) => void) => {
    const allowed = ['open-party', 'open-tmdb-id', 'menu', 'update-check-result', 'update-download-progress', 'embed-sniffed', 'maximized', 'link']
    if (!allowed.includes(channel)) return () => {}
    const listener = (_e: unknown, v: unknown) => cb(v)
    ipcRenderer.on(channel, listener)
    return () => ipcRenderer.removeListener(channel, listener)
  }) as VelaApi['on']
}

contextBridge.exposeInMainWorld('vela', api)
