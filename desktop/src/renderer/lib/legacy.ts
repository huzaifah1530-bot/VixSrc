// Reads the v1 desktop ("VixScr") localStorage keys so a first launch of
// Vela keeps favourites, history and settings. Main copies the old profile's
// Local Storage folder over; this converts the shapes. Servers are not
// migrated — Vela uses the current iOS server list instead.
import type { MediaItem } from '@shared/types'

const OLD_DEFAULT_KEY = 'ce5e1892fe2fdf9006a6b4dfabe1fea4'

function read<T>(key: string): T | null {
  try { const v = localStorage.getItem(key); return v === null ? null : (JSON.parse(v) as T) } catch { return localStorage.getItem(key) as T | null }
}

function toItem(x: any): MediaItem | null {
  if (!x || (x.type !== 'movie' && x.type !== 'tv') || !(x.tmdbId ?? x.id)) return null
  return {
    tmdbId: String(x.tmdbId ?? x.id),
    type: x.type,
    title: String(x.title ?? ''),
    description: String(x.description ?? ''),
    posterPath: x.posterPath ?? null,
    backdropPath: x.backdropPath ?? x.posterPath ?? null,
    rating: typeof x.rating === 'number' ? x.rating : null,
    year: String(x.year ?? ''),
    popularity: Number(x.popularity ?? 0),
    resumeSeason: x.resumeSeason ?? x.season ?? x.seasonNumber ?? null,
    resumeEpisode: x.resumeEpisode ?? x.episode ?? x.episodeNumber ?? null,
    resumeTitle: x.resumeTitle ?? x.episodeName ?? null,
    updatedAt: x.updatedAt ? new Date(x.updatedAt).toISOString() : null
  }
}

export function legacyLibrary() {
  const favorites = (read<unknown[]>('vixsrc_live_favorites') ?? []).map(toItem).filter((i): i is MediaItem => !!i)
  const recents = (read<unknown[]>('vixsrc_live_recents') ?? []).map(toItem).filter((i): i is MediaItem => !!i)
  const searchHistory = (read<unknown[]>('vixsrc_live_search_history') ?? []).filter((s): s is string => typeof s === 'string')
  return { favorites, recents, searchHistory }
}

export function legacySettings() {
  const cred = localStorage.getItem('vixsrc_live_tmdb_credential')?.trim() ?? ''
  return {
    credential: cred && cred !== OLD_DEFAULT_KEY ? cred : '',
    cardSize: localStorage.getItem('vixsrc_live_card_size') === 'compact' ? 'compact' as const : 'large' as const,
    performanceMode: localStorage.getItem('vixsrc_live_perf_mode') === 'true',
    ultraPerformanceMode: localStorage.getItem('vixsrc_live_ultra_perf_mode') === 'true'
  }
}
