// Applies Windows' caption style (Settings › Accessibility › Captions) to the
// captions Vela draws. Re-read whenever the window regains focus, so changes
// made in Windows Settings show up as soon as the user comes back.
import { useEffect, useState } from 'react'
import type { SystemCaptionStyle } from '@shared/types'

const rgba = (hex: string, alpha: number) => {
  const n = parseInt(hex.slice(1), 16)
  return `rgba(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}, ${alpha})`
}

const EDGE_SHADOWS: Record<NonNullable<SystemCaptionStyle['edge']>, string> = {
  none: 'none',
  raised: '-1px -1px 0 rgba(255,255,255,.35), 1px 1px 0 rgba(0,0,0,.9)',
  depressed: '1px 1px 0 rgba(255,255,255,.35), -1px -1px 0 rgba(0,0,0,.9)',
  uniform: '0 0 2px #000, 0 0 2px #000, 0 0 2px #000, 0 0 2px #000',
  shadow: '2px 2px 3px rgba(0,0,0,.9)'
}

/** CSS custom properties consumed by `.caption` in player.css. */
export function useSystemCaptionStyle(): React.CSSProperties {
  const [style, setStyle] = useState<SystemCaptionStyle | null>(null)
  useEffect(() => {
    let live = true
    const read = () => window.vela.captions?.systemStyle().then(s => { if (live) setStyle(s) }).catch(() => {})
    read()
    window.addEventListener('focus', read)
    return () => { live = false; window.removeEventListener('focus', read) }
  }, [])
  if (!style) return {}
  const vars: Record<string, string> = {}
  if (style.textColor) vars['--caption-color'] = rgba(style.textColor, style.textOpacity ?? 1)
  else if (style.textOpacity != null) vars['--caption-color'] = `rgba(255,255,255,${style.textOpacity})`
  if (style.backgroundColor || style.backgroundOpacity != null) {
    vars['--caption-bg'] = rgba(style.backgroundColor ?? '#000000', style.backgroundOpacity ?? 0.72)
  }
  if (style.windowColor && style.windowOpacity) vars['--caption-window'] = rgba(style.windowColor, style.windowOpacity)
  if (style.scale) vars['--caption-system-scale'] = String(style.scale)
  if (style.fontFamily) vars['--caption-font'] = style.fontFamily
  if (style.smallCaps) vars['--caption-variant'] = 'small-caps'
  if (style.edge) vars['--caption-edge'] = EDGE_SHADOWS[style.edge]
  return vars as React.CSSProperties
}
