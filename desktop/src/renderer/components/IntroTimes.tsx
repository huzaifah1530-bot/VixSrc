// Intro start / end for a show. With no custom times the boxes show the
// intro found for `episodeLabel`'s episode (TheIntroDB / AniSkip), which can
// differ per episode; 00:00 → 00:00 when nothing is found. Typing new times
// saves a custom intro used for every episode; Reset goes back to found.
import { useEffect, useState } from 'react'
import type { MediaItem, SkipSegment } from '@shared/types'
import { showKey, validSegments } from '@shared/introSkip'
import { useSettings } from '@/stores/settings'
import { formatTime } from '@/lib/format'
import { Icon } from './Icon'

/** "1:30", "01:02:03" or "90" → seconds; null when it isn't a time. */
export function parseClock(text: string): number | null {
  const t = text.trim()
  if (!t) return 0
  if (!/^\d+(:\d{1,2}){0,2}$/.test(t)) return null
  const parts = t.split(':').map(Number)
  if (parts.slice(1).some(p => p > 59)) return null
  return parts.reduce((acc, p) => acc * 60 + p, 0)
}

const clock = (s: number) => (s >= 3600 ? formatTime(s) : `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(Math.floor(s % 60)).padStart(2, '0')}`)

export function IntroTimes({ item, episodeLabel, lookup }: {
  item: MediaItem
  /** e.g. "S1 · E3", the episode `lookup` finds times for. */
  episodeLabel?: string | null
  lookup?: (() => Promise<SkipSegment[]>) | null
}) {
  const key = showKey(item)
  const saved = useSettings(s => s.introOverrides?.[key])
  const set = useSettings(s => s.set)
  const [found, setFound] = useState<SkipSegment | null>(null)
  const custom = !!saved && saved.start != null && saved.end != null

  useEffect(() => {
    setFound(null)
    if (!lookup) return
    let live = true
    lookup().then(list => { if (live) setFound(validSegments(list, 0).find(s => s.kind === 'intro') ?? null) }).catch(() => {})
    return () => { live = false }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, episodeLabel])

  const shownStart = custom ? saved!.start! : found?.start ?? 0
  const shownEnd = custom ? saved!.end! : found?.end ?? 0
  const [start, setStart] = useState('')
  const [end, setEnd] = useState('')
  useEffect(() => { setStart(clock(shownStart)); setEnd(clock(shownEnd)) }, [shownStart, shownEnd])

  const s = parseClock(start), e = parseClock(end)
  const zero = s === 0 && e === 0
  const invalid = s === null || e === null || (!zero && !(e! > s!))

  const save = (all: Record<string, NonNullable<typeof saved>>) => set({ introOverrides: all })
  const reset = () => {
    const all = { ...(useSettings.getState().introOverrides ?? {}) }
    delete all[key]
    save(all)
    setStart(clock(found?.start ?? 0)); setEnd(clock(found?.end ?? 0))
  }
  const commit = () => {
    if (invalid) return
    // Unchanged from what's shown: nothing to save.
    if (Math.round(s!) === Math.round(shownStart) && Math.round(e!) === Math.round(shownEnd)) return
    if (zero) { reset(); return }
    save({ ...(useSettings.getState().introOverrides ?? {}), [key]: { title: item.title, start: s, end: e } })
  }

  const hint = invalid
    ? 'Use mm:ss, with the end after the start.'
    : custom ? 'Custom: used for every episode of this show.'
      : found ? `Found for ${episodeLabel ?? 'this episode'} (can differ per episode). Edit to set your own for all episodes.`
        : `No intro found${episodeLabel ? ` for ${episodeLabel}` : ''}. Enter times to set one for all episodes.`

  return (
    <section className="intro-times" aria-label="Intro times">
      <table>
        <thead>
          <tr><th scope="col">Intro start</th><th scope="col">Intro end</th><th aria-hidden="true" /></tr>
        </thead>
        <tbody>
          <tr>
            <td><input className="text-input" aria-label="Intro start (mm:ss)" value={start} inputMode="numeric" placeholder="00:00" spellCheck={false}
              onChange={ev => setStart(ev.target.value)} onBlur={commit} onKeyDown={ev => ev.key === 'Enter' && commit()} /></td>
            <td><input className="text-input" aria-label="Intro end (mm:ss)" value={end} inputMode="numeric" placeholder="00:00" spellCheck={false}
              onChange={ev => setEnd(ev.target.value)} onBlur={commit} onKeyDown={ev => ev.key === 'Enter' && commit()} /></td>
            <td>
              <button className="tb-btn intro-reset" aria-label="Reset to found intro times" title="Reset to found times" disabled={!custom} onClick={reset}>
                <Icon name="refresh" size={13} />
              </button>
            </td>
          </tr>
        </tbody>
      </table>
      <p className="form-hint" role={invalid ? 'alert' : undefined}>{hint}</p>
    </section>
  )
}
