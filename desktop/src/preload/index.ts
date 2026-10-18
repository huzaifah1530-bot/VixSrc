import { contextBridge, ipcRenderer } from 'electron'
import type { VelaApi } from '@shared/types'

const api: VelaApi = {
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
    apply: exe => ipcRenderer.invoke('update:apply', exe)
  },
  saveFile: (name, contents) => ipcRenderer.invoke('save-file', name, contents),
  openFile: () => ipcRenderer.invoke('open-file'),
  openExternal: url => ipcRenderer.send('open-external', url),
  on: ((channel: string, cb: (v: unknown) => void) => {
    const allowed = ['open-tmdb-id', 'menu', 'update-check-result', 'update-download-progress', 'embed-sniffed', 'maximized']
    if (!allowed.includes(channel)) return () => {}
    const listener = (_e: unknown, v: unknown) => cb(v)
    ipcRenderer.on(channel, listener)
    return () => ipcRenderer.removeListener(channel, listener)
  }) as VelaApi['on']
}

contextBridge.exposeInMainWorld('vela', api)
