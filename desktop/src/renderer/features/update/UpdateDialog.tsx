import { useEffect, useState } from 'react'
import { create } from 'zustand'
import type { UpdateCheckResult } from '@shared/types'
import { toast } from '@/stores/ui'

/** Latest-release info from the launch check; set when a newer version exists. */
export const useUpdate = create<{ result: UpdateCheckResult | null }>(() => ({ result: null }))

/** Shown once per launch when the releases repo has a newer version. */
export function UpdateDialog() {
  const result = useUpdate(s => s.result)
  const [progress, setProgress] = useState<number | null>(null)
  const dismiss = () => useUpdate.setState({ result: null })
  useEffect(() => window.vela.on('update-download-progress', setProgress), [])
  useEffect(() => {
    if (!result) return
    const k = (e: KeyboardEvent) => { if (e.key === 'Escape' && progress === null) dismiss() }
    window.addEventListener('keydown', k)
    return () => window.removeEventListener('keydown', k)
  }, [result, progress])
  if (!result?.updateAvailable) return null
  const install = async () => {
    setProgress(0)
    const r = await window.vela.updater.apply(result.downloadUrl, result.releaseUrl)
    if (!r.ok) { setProgress(null); toast(r.error ?? 'Update failed'); dismiss() }
  }

  return (
    <div className="sheet-backdrop" onMouseDown={() => progress === null && dismiss()}>
      <div className="sheet glass-strong" role="alertdialog" aria-modal="true" aria-labelledby="update-title" onMouseDown={e => e.stopPropagation()}>
        <h2 id="update-title" className="sheet-title">Vela {result.latestVersion} is available</h2>
        <p className="muted sheet-sub">
          You’re on {result.currentVersion}. Install runs the setup wizard; if that doesn’t work, the download page opens instead.
        </p>
        {result.notes && <p className="form-hint update-notes">{result.notes}</p>}
        <div className="sheet-actions">
          <button className="btn" disabled={progress !== null} onClick={dismiss}>Later</button>
          <button className="btn" disabled={progress !== null} onClick={() => { window.vela.openExternal(result.releaseUrl ?? 'https://github.com/huzaifah1530-bot/Vela/releases/latest'); dismiss() }}>View Release</button>
          <button className="btn btn-primary" disabled={progress !== null} onClick={install}>
            {progress !== null ? `Downloading ${Math.round(progress * 100)}%` : 'Install'}
          </button>
        </div>
      </div>
    </div>
  )
}
