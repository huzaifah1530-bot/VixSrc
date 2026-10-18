// Backup document shared with the iOS app (AppStore.Backup, version 1).
import type { MediaItem, WatchProgress } from '@shared/types'
import { useLibrary } from '@/stores/library'
import { DEFAULT_SERVERS, SEEK_OPTIONS, useSettings } from '@/stores/settings'
import { toast } from '@/stores/ui'
import { uuid } from './format'

// Swift's .iso8601 strategy rejects fractional seconds.
const iso = (d?: string | null) => (d ? new Date(d).toISOString().replace(/\.\d{3}Z$/, 'Z') : undefined)

export function buildBackup(): string {
  const s = useSettings.getState(), l = useLibrary.getState()
  const item = (i: MediaItem) => ({ ...i, updatedAt: iso(i.updatedAt) })
  const doc = {
    app: 'Vela',
    version: 1,
    exportedAt: iso(new Date().toISOString()),
    credential: s.credential,
    favorites: l.favorites.map(item),
    recents: l.recents.map(item),
    watchProgress: l.watchProgress.map(p => ({ ...p, lastWatchedAt: iso(p.lastWatchedAt) })),
    searchHistory: l.searchHistory,
    animeSearchHistory: l.animeSearchHistory,
    seekInterval: s.seekInterval,
    animeEnabled: s.animeEnabled,
    servers: s.servers,
    animeServers: s.animeServers,
    contentFilter: s.contentFilter,
    cardSize: s.cardSize,
    performanceMode: s.performanceMode,
    ultraPerformanceMode: s.ultraPerformanceMode
  }
  return JSON.stringify(doc, null, 2)
}

export function applyBackup(text: string) {
  const b = JSON.parse(text)
  if (b?.app !== 'Vela') throw new Error('This file isn’t a Vela backup.')
  const servers = (list: any[] | undefined) => (list ?? []).filter(x => x?.name && x?.base).map(x => ({ id: String(x.id ?? uuid()), name: String(x.name), base: String(x.base) }))
  useLibrary.getState().replaceAll({
    favorites: (b.favorites ?? []) as MediaItem[],
    recents: (b.recents ?? []) as MediaItem[],
    watchProgress: (b.watchProgress ?? []) as WatchProgress[],
    searchHistory: b.searchHistory ?? [],
    animeSearchHistory: b.animeSearchHistory ?? []
  })
  const regular = servers(b.servers)
  useSettings.getState().set({
    credential: b.credential ?? '',
    servers: regular.length ? regular : DEFAULT_SERVERS,
    animeServers: servers(b.animeServers),
    animeEnabled: b.animeEnabled ?? true,
    seekInterval: SEEK_OPTIONS.includes(b.seekInterval) ? b.seekInterval : 10,
    contentFilter: ['all', 'movie', 'tv'].includes(b.contentFilter) ? b.contentFilter : 'all',
    cardSize: b.cardSize === 'compact' ? 'compact' : 'large',
    performanceMode: !!b.performanceMode,
    ultraPerformanceMode: !!b.ultraPerformanceMode
  })
}

export async function exportBackup() {
  const date = new Date().toISOString().slice(0, 10)
  if (await window.vela.saveFile(`Vela Backup ${date}.json`, buildBackup())) toast('Backup exported')
}

export async function importBackup() {
  const text = await window.vela.openFile()
  if (!text) return
  try { applyBackup(text); toast('Backup imported') } catch (err) { toast((err as Error).message) }
}
