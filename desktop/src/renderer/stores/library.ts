import { create } from 'zustand'
import { persist } from 'zustand/middleware'
import type { MediaItem, WatchProgress } from '@shared/types'
import { legacyLibrary } from '@/lib/legacy'
import { isAnimeCatalog, itemKey } from '@/lib/tmdb'

interface LibraryState {
  favorites: MediaItem[]
  recents: MediaItem[]
  watchProgress: WatchProgress[]
  searchHistory: string[]
  animeSearchHistory: string[]
  toggleFavorite: (item: MediaItem) => boolean
  addRecent: (item: MediaItem, season?: number | null, episode?: number | null, episodeTitle?: string | null) => void
  removeFromHistory: (item: MediaItem) => void
  saveProgress: (p: WatchProgress) => void
  addSearch: (q: string, anime?: boolean) => void
  clearSearches: (anime?: boolean) => void
  replaceAll: (data: Partial<Pick<LibraryState, 'favorites' | 'recents' | 'watchProgress' | 'searchHistory' | 'animeSearchHistory'>>) => void
}

const KEY = 'vela_library'
const fresh = !localStorage.getItem(KEY)

export const useLibrary = create<LibraryState>()(
  persist(
    (set, get) => ({
      favorites: [],
      recents: [],
      watchProgress: [],
      searchHistory: [],
      animeSearchHistory: [],
      ...(fresh ? legacyLibrary() : {}),

      toggleFavorite: item => {
        const k = itemKey(item)
        const exists = get().favorites.some(f => itemKey(f) === k)
        set(s => ({ favorites: exists ? s.favorites.filter(f => itemKey(f) !== k) : [item, ...s.favorites].slice(0, 100) }))
        return !exists
      },
      addRecent: (item, season = null, episode = null, episodeTitle = null) => {
        const snap: MediaItem = { ...item, resumeSeason: season, resumeEpisode: episode, resumeTitle: episodeTitle, updatedAt: new Date().toISOString() }
        set(s => ({ recents: [snap, ...s.recents.filter(r => itemKey(r) !== itemKey(item))].slice(0, 24) }))
      },
      removeFromHistory: item => set(s => ({
        recents: s.recents.filter(r => itemKey(r) !== itemKey(item)),
        watchProgress: s.watchProgress.filter(p => item.type === 'movie' ? p.id !== `movie:${item.tmdbId}` : !p.id.startsWith(`tv:${item.tmdbId}:`))
      })),
      saveProgress: p => set(s => ({ watchProgress: [p, ...s.watchProgress.filter(x => x.id !== p.id)].slice(0, 300) })),
      addSearch: (q, anime) => {
        const clean = q.trim()
        if (clean.length < 2) return
        const key = anime ? 'animeSearchHistory' : 'searchHistory'
        set(s => ({ [key]: [clean, ...s[key].filter(x => x.toLowerCase() !== clean.toLowerCase())].slice(0, 12) }) as Partial<LibraryState>)
      },
      clearSearches: anime => set(anime ? { animeSearchHistory: [] } : { searchHistory: [] }),
      replaceAll: data => set(data)
    }),
    {
      name: KEY,
      version: 1,
      partialize: s => ({ favorites: s.favorites, recents: s.recents, watchProgress: s.watchProgress, searchHistory: s.searchHistory, animeSearchHistory: s.animeSearchHistory })
    }
  )
)

window.addEventListener('storage', e => { if (e.key === KEY) useLibrary.persist.rehydrate() })

// ── Selectors ─────────────────────────────────────────────────────────
export const useIsFavorite = (item: MediaItem | null | undefined) =>
  useLibrary(s => !!item && s.favorites.some(f => itemKey(f) === itemKey(item)))

const byDate = (a: MediaItem, b: MediaItem) => (b.updatedAt ?? '').localeCompare(a.updatedAt ?? '')
export const homeRecents = (r: MediaItem[]) => [...r].sort(byDate).filter(i => !i.anime && !isAnimeCatalog(i))
export const animeRecents = (r: MediaItem[]) => [...r].sort(byDate).filter(isAnimeCatalog)

export function progressFor(list: WatchProgress[], item: MediaItem): WatchProgress | undefined {
  if (item.type === 'movie') return list.find(p => p.id === `movie:${item.tmdbId}`)
  if (item.resumeSeason != null && item.resumeEpisode != null) return list.find(p => p.id === `tv:${item.tmdbId}:${item.resumeSeason}:${item.resumeEpisode}`)
  return list.find(p => p.id.startsWith(`tv:${item.tmdbId}:`))
}
export const progressFraction = (p?: WatchProgress) => (p && p.duration > 0 ? Math.min(1, p.position / p.duration) : 0)
