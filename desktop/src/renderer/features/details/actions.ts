import type { MediaItem } from '@shared/types'
import { tmdb, type TvDetails } from '@/lib/tmdb'
import { usePlayer, type TvContext } from '@/stores/player'
import { toast } from '@/stores/ui'

export const seasonsOf = (d: TvDetails) =>
  d.seasons.filter(s => s.season_number > 0 && s.episode_count > 0).map(s => ({ seasonNumber: s.season_number, episodeCount: s.episode_count }))

/** Play straight from a card or the hero: movies start, shows resume. */
export async function quickPlay(item: MediaItem) {
  if (item.type === 'movie') { usePlayer.getState().playTmdb(item); return }
  try {
    const d = await tmdb<TvDetails>(`/tv/${item.tmdbId}`)
    const seasons = seasonsOf(d)
    if (!seasons.length) { toast('No episodes listed for this show yet'); return }
    const ctx: TvContext = {
      seasons,
      season: item.resumeSeason ?? seasons[0].seasonNumber,
      episode: item.resumeEpisode ?? 1,
      episodeTitle: item.resumeTitle ?? null
    }
    usePlayer.getState().playTmdb(item, ctx)
  } catch (err) {
    toast((err as Error).message)
  }
}
