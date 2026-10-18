// Port of iOS WebVTT.swift — minimal parser for side-loaded subtitles.
export interface Cue { start: number; end: number; text: string }

function seconds(stamp: string): number | null {
  const parts = stamp.replace(',', '.').split(':')
  if (parts.length < 2 || parts.length > 3) return null
  let total = 0
  for (const p of parts) {
    const v = Number(p)
    if (Number.isNaN(v)) return null
    total = total * 60 + v
  }
  return total
}

export function parseVtt(text: string): Cue[] {
  const lines = text.replace(/\r\n?/g, '\n').split('\n')
  const cues: Cue[] = []
  for (let i = 0; i < lines.length; i++) {
    if (!lines[i].includes('-->')) continue
    const [a, b = ''] = lines[i].split('-->')
    const start = seconds(a.trim()), end = seconds(b.trim().split(' ')[0] ?? '')
    if (start === null || end === null) continue
    const body: string[] = []
    while (i + 1 < lines.length && lines[i + 1].trim()) body.push(lines[++i])
    const clean = body.join('\n')
      .replace(/<[^>]+>/g, '')
      .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&nbsp;/g, ' ')
      .trim()
    if (clean) cues.push({ start, end, text: clean })
  }
  return cues.sort((x, y) => x.start - y.start)
}

/** Text for every cue active at `t` (overlapping signs + dialogue render together). */
export function captionAt(cues: Cue[], t: number): string | null {
  let lo = 0, hi = cues.length - 1, found = -1
  while (lo <= hi) {
    const mid = (lo + hi) >> 1
    if (cues[mid].start <= t) { found = mid; lo = mid + 1 } else hi = mid - 1
  }
  const lines: string[] = []
  for (let i = found; i >= 0 && i >= found - 4; i--) {
    if (cues[i].start <= t && cues[i].end > t) lines.unshift(cues[i].text)
  }
  return lines.length ? lines.join('\n') : null
}
