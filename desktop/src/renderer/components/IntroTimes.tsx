// Per-show custom intro: two timestamps under the show's actions. They
// replace TheIntroDB / AniSkip times for every episode. Both 00:00 = off.
import { useEffect, useState } from 'react'
import type { MediaItem } from '@shared/types'
import { showKey } from '@shared/introSkip'
import { useSettings } from '@/stores/settings'
import { formatTime } from '@/lib/format'

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

export function IntroTimes({ item }: { item: MediaItem }) {
  const key = showKey(item)
  const saved = useSettings(s => s.introOverrides?.[key])
  const set = useSettings(s => s.set)
  const [start, setStart] = useState('')
  const [end, setEnd] = useState('')
  useEffect(() => { setStart(clock(saved?.start ?? 0)); setEnd(clock(saved?.end ?? 0)) }, [saved?.start, saved?.end, key])

  const s = parseClock(start), e = parseClock(end)
  const off = s === 0 && e === 0
  const invalid = s === null || e === null || (!off && !(e! > s!))

  const commit = () => {
    if (invalid) return
    const all = { ...(useSettings.getState().introOverrides ?? {}) }
    if (off) delete all[key]
    else all[key] = { title: item.title, start: s, end: e }
    set({ introOverrides: all })
  }

  return (
    <section className="intro-times" aria-label="Custom intro times">
      <table>
        <thead>
          <tr><th scope="col">Intro start</th><th scope="col">Intro end</th></tr>
        </thead>
        <tbody>
          <tr>
            <td><input className="text-input" aria-label="Intro start (mm:ss)" value={start} inputMode="numeric" placeholder="00:00" spellCheck={false}
              onChange={ev => setStart(ev.target.value)} onBlur={commit} onKeyDown={ev => ev.key === 'Enter' && commit()} /></td>
            <td><input className="text-input" aria-label="Intro end (mm:ss)" value={end} inputMode="numeric" placeholder="00:00" spellCheck={false}
              onChange={ev => setEnd(ev.target.value)} onBlur={commit} onKeyDown={ev => ev.key === 'Enter' && commit()} /></td>
          </tr>
        </tbody>
      </table>
      <p className="form-hint" role={invalid ? 'alert' : undefined}>
        {invalid
          ? 'Use mm:ss, with the end after the start.'
          : off ? 'Off: using TheIntroDB / AniSkip times when they exist. Both 00:00 = off.'
            : 'Skip Intro uses these times for every episode of this show.'}
      </p>
    </section>
  )
}
