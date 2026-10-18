import { create } from 'zustand'
import { persist } from 'zustand/middleware'
import type { AnimeServer, StreamServer } from '@shared/types'
import { legacySettings } from '@/lib/legacy'
import { uuid } from '@/lib/format'

export const DEFAULT_SERVERS: StreamServer[] = [
  { id: uuid(), name: 'VixSrc', base: 'https://vixsrc.to' },
  { id: uuid(), name: 'ApiPlayer', base: 'https://apiplayer.ru/embed' },
  { id: uuid(), name: 'Cinezo', base: 'https://player.cinezo.live/embed' },
  { id: uuid(), name: 'Vidlink', base: 'https://vidlink.pro' },
  { id: uuid(), name: 'VidSrc', base: 'https://vidsrc.wiki/embed' }
]
export const DEFAULT_ANIME_SERVERS: AnimeServer[] = [
  { id: uuid(), name: 'AnimeKai', base: 'https://animekaitv.to' },
  { id: uuid(), name: 'AniKoto', base: 'https://anikototv.to' }
]
export const SEEK_OPTIONS = [5, 10, 15, 30] as const
export type ContentFilter = 'all' | 'movie' | 'tv'
export type CardSize = 'compact' | 'large'

export interface SettingsState {
  credential: string
  servers: StreamServer[]
  animeServers: AnimeServer[]
  animeEnabled: boolean
  seekInterval: number
  cardSize: CardSize
  performanceMode: boolean
  ultraPerformanceMode: boolean
  contentFilter: ContentFilter
  sidebarCollapsed: boolean
  volume: number
  muted: boolean
  set: (patch: Partial<Omit<SettingsState, 'set'>>) => void
}

const KEY = 'vela_settings'
const fresh = !localStorage.getItem(KEY)

export const useSettings = create<SettingsState>()(
  persist(
    set => ({
      credential: '',
      servers: DEFAULT_SERVERS,
      animeServers: DEFAULT_ANIME_SERVERS,
      animeEnabled: true,
      seekInterval: 10,
      cardSize: 'large',
      performanceMode: false,
      ultraPerformanceMode: false,
      contentFilter: 'all',
      sidebarCollapsed: false,
      volume: 1,
      muted: false,
      ...(fresh ? legacySettings() : {}),
      set: patch => set(patch)
    }),
    { name: KEY, version: 1 }
  )
)

// Keep the main and Settings windows in sync.
window.addEventListener('storage', e => { if (e.key === KEY) useSettings.persist.rehydrate() })
