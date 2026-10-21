// Skip Intro for the native player. Timestamps load in the background once
// the video's duration is known (so the right release version is picked);
// playback never waits for them, and any failure just means no button.
import { useEffect, useMemo, useRef, useState } from 'react'
import type { SkipSegment } from '@shared/types'
import { AutoSkipTracker, activeIntro, showKey, validSegments, withOverride } from '@shared/introSkip'
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
  const episodeKey = usePlayer(s => (s.kind === 'anime' || s.tv ? s.progressId : ''))
  const source = usePlayer(s => s.sources[s.sourceIndex])
  const auto = useSettings(s => s.autoSkipIntro)
  const isHost = useParty(s => s.active && s.isHost)
  const [remote, setRemote] = useState<SkipSegment[]>([])

  // Timestamps the stream itself carries (anime hosts) win over lookups.
  const ownIntro = useMemo(() => (source?.segments ?? []).some(s => s.kind === 'intro'), [source])

  // ── Background lookup (TheIntroDB for TV, AniSkip for anime) ─────────
  const known = duration > 0 && Number.isFinite(duration)
  const [graceOver, setGraceOver] = useState(false)
  useEffect(() => {
    setGraceOver(false)
    const t = setTimeout(() => setGraceOver(true), DURATION_GRACE_MS)
    return () => clearTimeout(t)
  }, [episodeKey])

  useEffect(() => {
    setRemote(fetched.get(episodeKey) ?? [])
    if (!native || !episodeKey || ownIntro || fetched.has(episodeKey) || (!known && !graceOver)) return
    const p = usePlayer.getState()
    const len = known ? duration : 0
    let request: Promise<SkipSegment[]> | null = null
    if (kind === 'tmdb' && p.item?.type === 'tv' && p.tv) {
      request = window.vela.skip.tv(p.item.tmdbId, p.tv.season, p.tv.episode, len)
    } else if (kind === 'anime' && p.anime?.details.identity) {
      request = window.vela.skip.anime(p.anime.details.identity, p.anime.episode.number, len)
    }
    if (!request) return
    let live = true
    request.then(list => {
      // A newer episode may have opened meanwhile: drop stale answers.
      if (!live || usePlayer.getState().progressId !== episodeKey) return
      fetched.set(episodeKey, list)
      if (fetched.size > 200) fetched.delete(fetched.keys().next().value!)
      setRemote(list)
    }).catch(() => {})
    return () => { live = false }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [episodeKey, native, ownIntro, known, graceOver])

  // ── Per-show custom intro (overrides whatever was found) ─────────────
  const item = usePlayer(s => s.item)
  const key = item && (kind === 'anime' || item.type === 'tv') ? showKey(item) : null
  // Set in the table on the show's page (components/IntroTimes.tsx).
  const override = useSettings(s => (key ? s.introOverrides?.[key] ?? null : null))

  const segments = useMemo(
    () => validSegments(withOverride(ownIntro ? source!.segments! : remote, override), known ? duration : 0),
    [ownIntro, source, remote, override, known, duration]
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

  const intro = native ? activeIntro(segments, time) : null
  return {
    intro,
    skip: () => { if (intro) seekTo(intro.end) },
    segments
  }
}
