import { create } from 'zustand'
import { persist } from 'zustand/middleware'
import type { AnimeServer, IntroOverride, StreamServer } from '@shared/types'
import { legacySettings } from '@/lib/legacy'
import { uuid } from '@/lib/format'

export const DEFAULT_SERVERS: StreamServer[] = [
  { id: uuid(), name: 'VixSrc', base: 'https://vixsrc.to' },
  { id: uuid(), name: 'VidSrc', base: 'https://vidsrc.wiki/embed' }
]

const host = (base: string) => { try { return new URL(base).hostname.toLowerCase() } catch { return '' } }

/**
 * → v5: the server list is just VixSrc and VidSrc. Everything else (Nuvio
 * providers, NebulaStreams, ApiPlayer, Cinezo, Vidlink, user-added) is
 * dropped; VixSrc / VidSrc entries the user already had are kept.
 */
export function migrateServers(servers: StreamServer[]): StreamServer[] {
  const kept = DEFAULT_SERVERS.map(d => servers.find(s => host(s.base) === host(d.base)) ?? { ...d, id: uuid() })
  return kept
}
export const DEFAULT_ANIME_SERVERS: AnimeServer[] = [
  { id: uuid(), name: 'AnimeKai', base: 'https://animekaitv.to' },
  { id: uuid(), name: 'AniKoto', base: 'https://anikototv.to' }
]
export const SEEK_OPTIONS = [5, 10, 15, 30] as const
export const CAPTION_SIZES = [{ v: 0.5, label: 'Tiny' }, { v: 0.65, label: 'Extra Small' }, { v: 0.8, label: 'Small' }, { v: 1, label: 'Medium' }, { v: 1.3, label: 'Large' }, { v: 1.6, label: 'Extra Large' }] as const
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
  /** Caption text scale, same steps as iOS (0.5 … 1.6). */
  captionScale: number
  /** Seek past known intros automatically (TheIntroDB / AniSkip). Off by default. */
  autoSkipIntro: boolean
  /** Per-show custom intro times, keyed `tv:<tmdbId>` or `tv:kai:<slug>`. */
  introOverrides: Record<string, IntroOverride>
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
      captionScale: 1,
      autoSkipIntro: false,
      introOverrides: {},
      ...(fresh ? legacySettings() : {}),
      set: patch => set(patch)
    }),
    {
      name: KEY,
      version: 5,
      migrate: (persisted, version) => {
        const s = (persisted ?? {}) as Partial<SettingsState>
        if (version < 5 && Array.isArray(s.servers)) s.servers = migrateServers(s.servers)
        return s as SettingsState
      }
    }
  )
)

// Keep the main and Settings windows in sync.
window.addEventListener('storage', e => { if (e.key === KEY) useSettings.persist.rehydrate() })
