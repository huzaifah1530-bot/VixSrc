// Forward deep-link TMDB ids (from launch args / vixscr:// protocol / a
// second app instance) to the renderer. nodeIntegration is enabled and
// contextIsolation is disabled for this window, so ipcRenderer is reachable
// directly and we can stash the id for the page script to pick up.
const { ipcRenderer } = require('electron');

window.__pendingTmdbId = null;
ipcRenderer.on('open-tmdb-id', (event, tmdbId) => {
  window.__pendingTmdbId = tmdbId;
  window.dispatchEvent(new CustomEvent('vixscr:open-tmdb-id', { detail: tmdbId }));
});

// ── Auto-update bridge ──
// Exposes a small API on window.vixscrUpdater for the Settings panel to
// check for and apply updates against the public GitHub-hosted release.
window.vixscrUpdater = {
  check: () => ipcRenderer.invoke('update:check'),
  apply: (exeName) => ipcRenderer.invoke('update:apply', exeName)
};

ipcRenderer.on('update-check-result', (event, result) => {
  window.dispatchEvent(new CustomEvent('vixscr:update-check-result', { detail: result }));
});

ipcRenderer.on('update-download-progress', (event, fraction) => {
  window.dispatchEvent(new CustomEvent('vixscr:update-download-progress', { detail: fraction }));
});

// Overrides window.open inside the renderer context as a fallback check
window.addEventListener('DOMContentLoaded', () => {
  const originalOpen = window.open;
  window.open = function (url, target, windowFeatures) {
    if (url) {
      try {
        const parsed = new URL(url, window.location.href);
        if (
          parsed.hostname === 'themoviedb.org' ||
          parsed.hostname.endsWith('.themoviedb.org') ||
          parsed.hostname === 'tmdb.org' ||
          parsed.hostname.endsWith('.tmdb.org')
        ) {
          return originalOpen.apply(window, arguments);
        }
      } catch (e) {
        // Fall through to default blocking if URL parsing fails
      }
    }
    return null; // Block non-TMDB popups silently
  };
});