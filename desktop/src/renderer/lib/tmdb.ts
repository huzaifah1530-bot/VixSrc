import type { MediaItem, MediaRow, MediaType } from '@shared/types'
import { useSettings } from '@/stores/settings'

export interface RawTmdbItem {
  id: number
  media_type?: string
  title?: string
  name?: string
  overview?: string
  poster_path?: string | null
  backdrop_path?: string | null
  vote_average?: number
  release_date?: string
  first_air_date?: string
  popularity?: number
  genre_ids?: number[]
  original_language?: string
  origin_country?: string[]
}

export interface TvSeason { season_number: number; name: string; episode_count: number; poster_path?: string | null }
export interface TvDetails { id: number; name: string; seasons: TvSeason[]; number_of_seasons: number; genres?: { id: number; name: string }[] }
export interface TvEpisode { episode_number: number; season_number: number; name: string; overview: string; still_path?: string | null; runtime?: number | null; air_date?: string }
export interface CastMember { id: number; name: string; character?: string; profile_path?: string | null }

export function tmdb<T>(path: string, params: Record<string, string | number | undefined> = {}): Promise<T> {
  const credential = useSettings.getState().credential.trim() || undefined
  return window.vela.tmdb(path, params, credential) as Promise<T>
}

/** TMDB has no anime type: Animation (16) + Japanese language or origin. */
export function isAnimeRaw(raw: RawTmdbItem) {
  return !!raw.genre_ids?.includes(16) && (raw.original_language === 'ja' || !!raw.origin_country?.includes('JP'))
}

export function normalize(raw: RawTmdbItem, forced?: MediaType): MediaItem | null {
  const type = (forced ?? raw.media_type) as MediaType
  if (type !== 'movie' && type !== 'tv') return null
  const title = type === 'movie' ? raw.title : raw.name
  if (!raw.id || !title) return null
  return {
    tmdbId: String(raw.id),
    type,
    title,
    description: raw.overview || 'No overview is available from TMDB for this title.',
    posterPath: raw.poster_path ?? null,
    backdropPath: raw.backdrop_path ?? raw.poster_path ?? null,
    rating: typeof raw.vote_average === 'number' ? raw.vote_average : null,
    year: (raw.release_date || raw.first_air_date || '').slice(0, 4),
    popularity: raw.popularity ?? 0,
    anime: isAnimeRaw(raw)
  }
}

export function imageUrl(path: string | null | undefined, size: 'w185' | 'w300' | 'w342' | 'w500' | 'w780' | 'w1280' | 'original' = 'w500') {
  if (!path) return ''
  if (path.startsWith('http')) return path
  return `https://image.tmdb.org/t/p/${size}${path}`
}

export const itemKey = (i: Pick<MediaItem, 'type' | 'tmdbId'>) => `${i.type}:${i.tmdbId}`
export const isAnimeCatalog = (i: MediaItem) => i.tmdbId.startsWith('kai:')
export const animeSlug = (i: MediaItem) => (isAnimeCatalog(i) ? i.tmdbId.slice(4) : null)

export function dedupe(items: (MediaItem | null)[]): MediaItem[] {
  const seen = new Set<string>()
  return items.filter((i): i is MediaItem => !!i && !seen.has(itemKey(i)) && !!seen.add(itemKey(i)))
}

export async function loadHomeRows(hideAnime: boolean): Promise<MediaRow[]> {
  type Page = { results: RawTmdbItem[] }
  const [trending, mp, tp, mt, tt] = await Promise.all([
    tmdb<Page>('/trending/all/week'),
    tmdb<Page>('/movie/popular', { page: 1 }),
    tmdb<Page>('/tv/popular', { page: 1 }),
    tmdb<Page>('/movie/top_rated', { page: 1 }),
    tmdb<Page>('/tv/top_rated', { page: 1 })
  ])
  const map = (p: Page, t?: MediaType) => dedupe(p.results.map(r => normalize(r, t))).filter(i => !hideAnime || !i.anime)
  return [
    { title: 'Trending this week', subtitle: 'Live from TMDB trending', items: map(trending) },
    { title: 'Popular movies', subtitle: 'Current TMDB movie results', items: map(mp, 'movie') },
    { title: 'Popular TV shows', subtitle: 'Current TMDB show results', items: map(tp, 'tv') },
    { title: 'Top rated movies', subtitle: 'Highly rated TMDB films', items: map(mt, 'movie') },
    { title: 'Top rated TV', subtitle: 'Highly rated TMDB series', items: map(tt, 'tv') }
  ].filter(r => r.items.length)
}

export async function searchTmdb(query: string, hideAnime: boolean): Promise<MediaItem[]> {
  const year = /\b(19|20)\d{2}\b/.exec(query)?.[0]
  const q = year ? query.replace(year, '').trim() : query
  const res = await tmdb<{ results: RawTmdbItem[] }>('/search/multi', { query: q || query, include_adult: 'false' })
  let items = dedupe(res.results.map(r => normalize(r))).filter(i => !hideAnime || !i.anime)
  if (year) items = [...items.filter(i => i.year === year), ...items.filter(i => i.year !== year)]
  // Light re-rank: exact / prefix title matches first, then popularity.
  const n = q.toLowerCase()
  const score = (i: MediaItem) => {
    const t = i.title.toLowerCase()
    return (t === n ? 3 : t.startsWith(n) ? 2 : t.includes(n) ? 1 : 0) * 1e6 + i.popularity
  }
  return year ? items : items.sort((a, b) => score(b) - score(a))
}
