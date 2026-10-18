export function formatTime(s: number) {
  if (!Number.isFinite(s) || s < 0) s = 0
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = Math.floor(s % 60)
  return h ? `${h}:${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}` : `${m}:${String(sec).padStart(2, '0')}`
}

export const uuid = () => crypto.randomUUID().toUpperCase()

export const cx = (...c: (string | false | null | undefined)[]) => c.filter(Boolean).join(' ')
