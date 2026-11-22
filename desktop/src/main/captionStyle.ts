// Windows "Caption style" (Settings › Accessibility › Captions). Vela draws
// its own captions, so it reads the same preferences Windows apps use and
// applies them. Values are the Windows.Media.ClosedCaptioning enums, stored
// under HKCU\Software\Microsoft\Windows\CurrentVersion\ClosedCaptioning.
import { execFile } from 'node:child_process'
import { shell } from 'electron'
import type { SystemCaptionStyle } from '@shared/types'

const KEY = 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\ClosedCaptioning'

// ClosedCaptionColor: 0 Default, 1 White … 8 Cyan
const COLORS = [null, '#ffffff', '#000000', '#ff0000', '#00ff00', '#0000ff', '#ffff00', '#ff00ff', '#00ffff'] as const
// ClosedCaptionOpacity: 0 Default, 1 100%, 2 75%, 3 25%, 4 0%
const OPACITY = [null, 1, 0.75, 0.25, 0] as const
// ClosedCaptionSize: 0 Default, 1 50%, 2 100%, 3 150%, 4 200%
const SIZES = [null, 0.5, 1, 1.5, 2] as const
// ClosedCaptionStyle: 0 Default, 1 mono serif, 2 serif, 3 mono sans, 4 sans, 5 casual, 6 cursive, 7 small caps
const FONTS = [
  null,
  '"Courier New", Courier, monospace',
  '"Times New Roman", Georgia, serif',
  'Consolas, "Lucida Console", monospace',
  null,
  '"Comic Sans MS", "Segoe Print", cursive',
  '"Segoe Script", "Lucida Handwriting", cursive',
  null
] as const
// ClosedCaptionEdgeEffect: 0 Default, 1 None, 2 Raised, 3 Depressed, 4 Uniform, 5 Drop shadow
const EDGES = [null, 'none', 'raised', 'depressed', 'uniform', 'shadow'] as const

function readRegistry(): Promise<Record<string, number>> {
  return new Promise(resolve => {
    if (process.platform !== 'win32') { resolve({}); return }
    execFile('reg', ['query', KEY], { windowsHide: true, timeout: 3000 }, (error, stdout) => {
      if (error) { resolve({}); return }
      const values: Record<string, number> = {}
      for (const match of stdout.matchAll(/^\s+(\w+)\s+REG_DWORD\s+0x([0-9a-f]+)/gim)) {
        values[match[1]] = parseInt(match[2], 16)
      }
      resolve(values)
    })
  })
}

const pick = <T>(table: readonly T[], value: number | undefined): T | null =>
  value === undefined ? null : (table[value] ?? null)

export async function systemCaptionStyle(): Promise<SystemCaptionStyle> {
  const v = await readRegistry()
  return {
    textColor: pick(COLORS, v.CaptionColor),
    textOpacity: pick(OPACITY, v.CaptionOpacity),
    scale: pick(SIZES, v.CaptionSize),
    fontFamily: pick(FONTS, v.CaptionFontStyle),
    smallCaps: v.CaptionFontStyle === 7,
    edge: pick(EDGES, v.CaptionEdgeEffect),
    backgroundColor: pick(COLORS, v.BackgroundColor),
    backgroundOpacity: pick(OPACITY, v.BackgroundOpacity),
    windowColor: pick(COLORS, v.RegionColor),
    windowOpacity: pick(OPACITY, v.RegionOpacity)
  }
}

export function openSystemCaptionSettings() {
  if (process.platform === 'win32') shell.openExternal('ms-settings:easeofaccess-closedcaptioning')
}
