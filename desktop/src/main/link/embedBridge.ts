// Control bridge for third-party web players running in the <webview>.
// Their <video> usually lives in a cross-origin iframe the renderer can't
// reach, so main runs small scripts in every frame of the webview and uses
// the first frame that has a real video.
import { webContents, type WebContents } from 'electron'

export interface EmbedState { position: number; duration: number; playing: boolean }

const STATE_JS = `(() => {
  const v = [...document.querySelectorAll('video')].filter(v => v.duration > 0 || v.readyState > 0)
    .sort((a, b) => (b.duration || 0) - (a.duration || 0))[0];
  return v ? { position: v.currentTime || 0, duration: isFinite(v.duration) ? v.duration : 0, playing: !v.paused && !v.ended } : null;
})()`

function controlJs(action: string, value: number) {
  return `(() => {
    const v = [...document.querySelectorAll('video')].filter(v => v.duration > 0 || v.readyState > 0)
      .sort((a, b) => (b.duration || 0) - (a.duration || 0))[0];
    if (!v) return false;
    const a = ${JSON.stringify(action)}, n = ${Number.isFinite(value) ? value : 0};
    if (a === 'play') v.play().catch(() => {});
    else if (a === 'pause') v.pause();
    else if (a === 'toggle') { v.paused ? v.play().catch(() => {}) : v.pause(); }
    else if (a === 'seek') v.currentTime = Math.max(0, Math.min(n, (v.duration || n + 1) - 0.5));
    else if (a === 'skip') v.currentTime = Math.max(0, Math.min(v.currentTime + n, (v.duration || Infinity) - 0.5));
    return true;
  })()`
}

function embedContents(): WebContents | null {
  // The newest live webview on the embed partition is the player.
  const all = webContents.getAllWebContents().filter(w => w.getType() === 'webview' && !w.isDestroyed())
  return all.sort((a, b) => b.id - a.id)[0] ?? null
}

async function inFrames<T>(code: string, gesture: boolean): Promise<T | null> {
  const wc = embedContents()
  if (!wc) return null
  for (const f of wc.mainFrame.framesInSubtree) {
    try {
      const r = await Promise.race([f.executeJavaScript(code, gesture), new Promise(res => setTimeout(() => res(null), 800))])
      if (r) return r as T
    } catch { /* detached or blocked frame */ }
  }
  return null
}

export const embedState = () => inFrames<EmbedState>(STATE_JS, false)

export async function embedControl(action: string, value = 0): Promise<boolean> {
  if (!['play', 'pause', 'toggle', 'seek', 'skip'].includes(action)) return false
  return !!(await inFrames<boolean>(controlJs(action, value), true))
}
