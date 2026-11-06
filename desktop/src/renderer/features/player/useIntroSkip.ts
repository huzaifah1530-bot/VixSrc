// Skip Intro for the native player. Timestamps load in the background once
// the video's duration is known (so the right release version is picked);
// playback never waits for them, and any failure just means no button.
import { useEffect, useMemo, useRef, useState } from 'react'
import type { SkipSegment } from '@shared/types'
import { AutoSkipTracker, activeSegment, mergeSegmentSources, showKey, skipTarget, validSegments, withOverride } from '@shared/introSkip'
import { usePlayer } from '@/stores/player'
import { useSettings } from '@/stores/settings'
import { partyActive, useParty } from '@/lib/party'

/** Fetched timestamps per episode key (the progress id), this session. */
const fetched = new Map<string, SkipSegment[]>()
/** Intros already auto-skipped or deliberately watched, per episode. */
const handled = new Map<string, Set<string>>()
const handledFor = (key: string) => {
  if (!handled.has(key)) { handled.clear(); handled.set(key, new Set()) }
  return handled.get(key)!
}

/** Wait this long for a duration before looking up without one. */
const DURATION_GRACE_MS = 6000

export function useIntroSkip(opts: { native: boolean; time: number; duration: number; seekTo: (t: number) => boolean }) {
  const { native, time, duration, seekTo } = opts
  const kind = usePlayer(s => s.kind)
  const episodeKey = usePlayer(s => s.progressId)
  const source = usePlayer(s => s.sources[s.sourceIndex])
  const auto = useSettings(s => s.autoSkipIntro)
  const isHost = useParty(s => s.active && s.isHost)
  const [remote, setRemote] = useState<SkipSegment[]>([])

  // ── Background lookup (SkipDB, then the older provider) ─────────────
  const known = duration > 0 && Number.isFinite(duration)
  const cacheKey = `${episodeKey}:${known ? Math.round(duration / 10) * 10 : 0}`
  const [graceOver, setGraceOver] = useState(false)
  useEffect(() => {
    setGraceOver(false)
    const t = setTimeout(() => setGraceOver(true), DURATION_GRACE_MS)
    return () => clearTimeout(t)
  }, [episodeKey])

  useEffect(() => {
    setRemote(fetched.get(cacheKey) ?? [])
    if (!native || !episodeKey || fetched.has(cacheKey) || (!known && !graceOver)) return
    const p = usePlayer.getState()
    const len = known ? duration : 0
    const credential = useSettings.getState().credential
    let request: Promise<SkipSegment[]> | null = null
    if (kind === 'tmdb' && p.item) {
      const item = p.item
      request = window.vela.tmdb(`/${item.type}/${item.tmdbId}/external_ids`, {}, credential)
        .then(raw => (raw as { imdb_id?: unknown })?.imdb_id)
        .catch(() => null)
        .then(imdb => item.type === 'tv' && p.tv
          ? window.vela.skip.tv(item.tmdbId, typeof imdb === 'string' ? imdb : '', p.tv!.season, p.tv!.episode, len)
          : window.vela.skip.movie(typeof imdb === 'string' ? imdb : '', len))
    } else if (kind === 'anime' && p.anime?.details.identity) {
      const identity = p.anime.details.identity
      request = window.vela.skip.anime(identity, p.anime.episode.number, len, credential)
    }
    if (!request) return
    let live = true
    request.then(list => {
      // A newer episode may have opened meanwhile: drop stale answers.
      if (!live || usePlayer.getState().progressId !== episodeKey) return
      fetched.set(cacheKey, list)
      if (fetched.size > 200) fetched.delete(fetched.keys().next().value!)
      setRemote(list)
    }).catch(() => {})
    return () => { live = false }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [episodeKey, cacheKey, native, known, graceOver])

  // ── Per-show custom intro (overrides whatever was found) ─────────────
  const item = usePlayer(s => s.item)
  const key = item && (kind === 'anime' || item.type === 'tv') ? showKey(item) : null
  // Set in the table on the show's page (components/IntroTimes.tsx).
  const override = useSettings(s => (key ? s.introOverrides?.[key] ?? null : null))

  const segments = useMemo(
    () => validSegments(withOverride(mergeSegmentSources(known ? duration : 0, remote, source?.segments ?? []), override), known ? duration : 0),
    [source, remote, override, known, duration]
  )

  // ── Auto-skip ─────────────────────────────────────────────────────────
  const tracker = useRef<AutoSkipTracker | null>(null)
  useEffect(() => { tracker.current = new AutoSkipTracker(handledFor(episodeKey)) }, [episodeKey])
  // A new source or newly arrived timestamps: treat the next tick as a start.
  useEffect(() => { tracker.current?.restart() }, [source?.url, segments])

  useEffect(() => {
    if (!native || !episodeKey || !segments.length || !tracker.current) return
    // In a watch party only the host skips, through the room's seek.
    const allowed = auto && (!partyActive() || isHost)
    const to = tracker.current.step(episodeKey, segments, time, allowed)
    if (to !== null) seekTo(to)
  }, [time, native, episodeKey, segments, auto, isHost, seekTo])

  const segment = native ? activeSegment(segments, time) : null
  return {
    segment,
    skip: () => { if (segment) seekTo(skipTarget(segment, segments, time)) },
    segments
  }
}
