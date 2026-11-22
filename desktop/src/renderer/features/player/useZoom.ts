// Scroll-wheel zoom for the player, centred on the cursor.
//
// 1× is the whole picture. The wheel goes down to 0.5× and up past 3×; when
// the wheel stops (the desktop equivalent of lifting your fingers) anything
// below 1× springs back to 1×, anything above 3× settles at 3×, and a zoom
// close to "fill the window" snaps onto it. The zoom and pan the user leaves
// are kept for the next video.
import { useCallback, useEffect, useRef, useState, type RefObject } from 'react'

const MIN = 0.5
const MAX = 3
/** How far past 3× the wheel can push before it stops responding. */
const OVERSHOOT = 0.6
const SETTLE_MS = 220
const SNAP_TOLERANCE = 0.07
const STORE_KEY = 'vela_player_zoom'

export type ZoomLabel = 'fill' | 'original' | null

interface Stored { scale: number; fx: number; fy: number; fill: boolean }

function load(): Stored {
  try {
    const s = JSON.parse(localStorage.getItem(STORE_KEY) ?? 'null') as Stored | null
    if (s && Number.isFinite(s.scale)) return { scale: Math.min(MAX, Math.max(1, s.scale)), fx: s.fx || 0, fy: s.fy || 0, fill: !!s.fill }
  } catch { /* fall through */ }
  return { scale: 1, fx: 0, fy: 0, fill: false }
}

export interface Zoom {
  /** Inline transform for the <video>. */
  transform: string
  /** True while the wheel is moving: transitions are off so it tracks 1:1. */
  adjusting: boolean
  scale: number
  filled: boolean
  /** Shown at the top of the player, e.g. "1.6×" or "Zoomed to fill". */
  indicator: string | null
  onWheel: (e: React.WheelEvent) => void
  toggleFill: () => void
  reset: () => void
}

export function useZoom(root: RefObject<HTMLElement | null>, video: RefObject<HTMLVideoElement | null>, rotation: number): Zoom {
  const initial = useRef(load()).current
  const [state, setState] = useState({ scale: initial.scale, x: 0, y: 0, fill: initial.fill })
  const [adjusting, setAdjusting] = useState(false)
  const [indicator, setIndicator] = useState<string | null>(null)
  const raw = useRef(initial.scale)
  const settleTimer = useRef<ReturnType<typeof setTimeout>>(undefined)
  const hideTimer = useRef<ReturnType<typeof setTimeout>>(undefined)
  const restored = useRef(false)

  /** Picture size at 1× (contain, after rotation) and the scale that fills the window. */
  const geometry = useCallback(() => {
    const el = root.current
    const W = el?.clientWidth || window.innerWidth
    const H = el?.clientHeight || window.innerHeight
    const v = video.current
    const vw = v?.videoWidth || 16
    const vh = v?.videoHeight || 9
    const k = Math.min(W / vw, H / vh)
    let pw = vw * k, ph = vh * k
    let base = 1
    if (rotation % 180 !== 0) {
      base = Math.min(W / ph, H / pw)
      ;[pw, ph] = [ph * base, pw * base]
    }
    return { W, H, pw, ph, base, fill: Math.max(W / pw, H / ph) }
  }, [root, video, rotation])

  const clamp = useCallback((scale: number, x: number, y: number) => {
    const g = geometry()
    const maxX = Math.max(0, (g.pw * scale - g.W) / 2)
    const maxY = Math.max(0, (g.ph * scale - g.H) / 2)
    return { x: Math.max(-maxX, Math.min(maxX, x)), y: Math.max(-maxY, Math.min(maxY, y)) }
  }, [geometry])

  const flash = useCallback((text: string) => {
    setIndicator(text)
    clearTimeout(hideTimer.current)
    hideTimer.current = setTimeout(() => setIndicator(null), 1100)
  }, [])

  const commit = useCallback((scale: number, x: number, y: number, fill: boolean) => {
    const g = geometry()
    const p = clamp(scale, x, y)
    raw.current = scale
    setState({ scale, x: p.x, y: p.y, fill })
    localStorage.setItem(STORE_KEY, JSON.stringify({ scale, fx: p.x / g.W, fy: p.y / g.H, fill } satisfies Stored))
  }, [clamp, geometry])

  // Restore the saved pan (stored relative to the window) once the video has a size.
  useEffect(() => {
    const v = video.current
    if (!v) return
    const apply = () => {
      if (restored.current) return
      restored.current = true
      const g = geometry()
      if (initial.fill) commit(g.fill, 0, 0, true)
      else commit(initial.scale, initial.fx * g.W, initial.fy * g.H, false)
    }
    if (v.videoWidth) apply()
    v.addEventListener('loadedmetadata', apply)
    return () => v.removeEventListener('loadedmetadata', apply)
  }, [video, geometry, commit, initial])

  // Keep "fill" filling (and the pan in bounds) when the window or rotation changes.
  useEffect(() => {
    const refit = () => setState(s => {
      const g = geometry()
      const scale = s.fill ? g.fill : s.scale
      return { ...s, scale, ...clamp(scale, s.x, s.y) }
    })
    refit()
    window.addEventListener('resize', refit)
    const v = video.current
    v?.addEventListener('resize', refit)
    return () => { window.removeEventListener('resize', refit); v?.removeEventListener('resize', refit) }
  }, [geometry, clamp, video])

  const settle = useCallback(() => {
    setAdjusting(false)
    const g = geometry()
    const current = raw.current
    let target = Math.min(MAX, Math.max(1, current))
    let label: ZoomLabel = null
    if (Math.abs(current - g.fill) / g.fill < SNAP_TOLERANCE && g.fill > 1.01) { target = g.fill; label = 'fill' }
    else if (Math.abs(current - 1) < SNAP_TOLERANCE || current < 1) { target = 1; label = 'original' }
    setState(s => {
      const ratio = target / s.scale
      const next = clamp(target, s.x * ratio, s.y * ratio)
      localStorage.setItem(STORE_KEY, JSON.stringify({ scale: target, fx: next.x / g.W, fy: next.y / g.H, fill: label === 'fill' } satisfies Stored))
      return { scale: target, ...next, fill: label === 'fill' }
    })
    raw.current = target
    flash(label === 'fill' ? 'Zoomed to fill' : label === 'original' && current !== 1 ? 'Original' : `${target.toFixed(1)}×`)
  }, [clamp, flash, geometry])

  const onWheel = useCallback((e: React.WheelEvent) => {
    const el = root.current
    if (!el || e.deltaY === 0) return
    // Trackpad pinches arrive as ctrl+wheel with small deltas.
    const speed = e.ctrlKey ? 0.012 : 0.0016
    const before = raw.current
    raw.current = Math.max(MIN, Math.min(MAX + OVERSHOOT, before * Math.exp(-e.deltaY * speed)))
    // Rubber band past 3×: it keeps moving, but less and less.
    const shown = raw.current > MAX ? MAX + (raw.current - MAX) * 0.45 : raw.current
    const r = el.getBoundingClientRect()
    const px = e.clientX - r.left - r.width / 2
    const py = e.clientY - r.top - r.height / 2
    setState(s => {
      const ratio = shown / s.scale
      // Keep the point under the cursor where it is.
      const x = px - (px - s.x) * ratio
      const y = py - (py - s.y) * ratio
      // Below 1× the whole picture is visible, so it simply stays centred.
      return { scale: shown, fill: false, ...(shown >= 1 ? clamp(shown, x, y) : { x: 0, y: 0 }) }
    })
    setAdjusting(true)
    setIndicator(`${shown.toFixed(1)}×`)
    clearTimeout(hideTimer.current)
    clearTimeout(settleTimer.current)
    settleTimer.current = setTimeout(settle, SETTLE_MS)
  }, [root, clamp, settle])

  const toggleFill = useCallback(() => {
    const g = geometry()
    if (state.fill || Math.abs(state.scale - g.fill) / g.fill < SNAP_TOLERANCE) {
      commit(1, 0, 0, false)
      flash('Original')
    } else {
      commit(g.fill, 0, 0, true)
      flash('Zoomed to fill')
    }
  }, [geometry, state, commit, flash])

  const reset = useCallback(() => { commit(1, 0, 0, false); flash('Original') }, [commit, flash])

  useEffect(() => () => { clearTimeout(settleTimer.current); clearTimeout(hideTimer.current) }, [])

  const base = geometry().base
  return {
    transform: `translate(${state.x}px, ${state.y}px) rotate(${rotation}deg) scale(${state.scale * base})`,
    adjusting,
    scale: state.scale,
    filled: state.fill,
    indicator,
    onWheel,
    toggleFill,
    reset
  }
}
