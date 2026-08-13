const { app, BrowserWindow, session, shell, ipcMain } = require('electron');
const path = require('path');
const fs = require('fs');
const https = require('https');
const { spawn } = require('child_process');
const { ElectronBlocker } = require('@ghostery/adblocker-electron');

// ── Auto-update (portable exe, GitHub-hosted) ──────────────────────
// The public repo only ever contains the latest VixScr.exe + version.json.
// We compare our own package.json version against version.json's "version"
// field. Update is fully anonymous/unauthenticated since the repo is public.
const UPDATE_MANIFEST_URL = 'https://raw.githubusercontent.com/huzaifah1530-bot/VixSrc-Public/main/version.json';
const UPDATE_EXE_BASE_URL = 'https://raw.githubusercontent.com/huzaifah1530-bot/VixSrc-Public/main/';

function compareVersions(a, b) {
  const pa = String(a).split('.').map(n => parseInt(n, 10) || 0);
  const pb = String(b).split('.').map(n => parseInt(n, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const diff = (pa[i] || 0) - (pb[i] || 0);
    if (diff !== 0) return diff > 0 ? 1 : -1;
  }
  return 0;
}

function httpsGetJson(url) {
  return new Promise((resolve, reject) => {
    const request = https.get(url, { headers: { 'User-Agent': 'VixScr-Updater' } }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        httpsGetJson(res.headers.location).then(resolve, reject);
        return;
      }
      if (res.statusCode !== 200) {
        reject(new Error('Update check failed: HTTP ' + res.statusCode));
        res.resume();
        return;
      }
      let raw = '';
      res.setEncoding('utf8');
      res.on('data', chunk => { raw += chunk; });
      res.on('end', () => {
        try {
          resolve(JSON.parse(raw));
        } catch (err) {
          reject(new Error('Update manifest was not valid JSON.'));
        }
      });
    });
    request.on('error', reject);
    request.setTimeout(15000, () => request.destroy(new Error('Update check timed out.')));
  });
}

function httpsDownloadFile(url, destPath, onProgress) {
  return new Promise((resolve, reject) => {
    const request = https.get(url, { headers: { 'User-Agent': 'VixScr-Updater' } }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        httpsDownloadFile(res.headers.location, destPath, onProgress).then(resolve, reject);
        return;
      }
      if (res.statusCode !== 200) {
        reject(new Error('Download failed: HTTP ' + res.statusCode));
        res.resume();
        return;
      }
      const total = parseInt(res.headers['content-length'] || '0', 10);
      let downloaded = 0;
      const fileStream = fs.createWriteStream(destPath);
      res.on('data', chunk => {
        downloaded += chunk.length;
        if (onProgress && total) onProgress(downloaded / total);
      });
      res.pipe(fileStream);
      fileStream.on('finish', () => fileStream.close(() => resolve(destPath)));
      fileStream.on('error', reject);
    });
    request.on('error', reject);
  });
}

async function checkForUpdate() {
  const manifest = await httpsGetJson(UPDATE_MANIFEST_URL);
  const latestVersion = String(manifest.version || '').trim();
  const currentVersion = app.getVersion();
  if (!latestVersion) throw new Error('Update manifest is missing a version.');
  const updateAvailable = compareVersions(latestVersion, currentVersion) > 0;
  return {
    updateAvailable,
    currentVersion,
    latestVersion,
    exeName: manifest.exe || 'VixScr.exe',
    notes: manifest.notes || ''
  };
}

async function downloadUpdate(exeName, onProgress) {
  const url = UPDATE_EXE_BASE_URL + exeName;
  const destPath = path.join(app.getPath('temp'), 'VixScr-update-' + Date.now() + '.exe');
  await httpsDownloadFile(url, destPath, onProgress);
  return destPath;
}

// Swaps the running portable exe for the freshly downloaded one, then
// relaunches. Windows won't let us delete/overwrite our own exe while it's
// running, so a tiny detached script does the swap after we quit.
// User data (localStorage/favorites/settings) lives in the Electron
// userData profile folder, not next to the exe, so it's untouched by this.
function applyUpdateAndRestart(downloadedExePath) {
  const currentExePath = app.getPath('exe');
  const exeDir = path.dirname(currentExePath);
  const exeName = path.basename(currentExePath);
  const backupPath = path.join(exeDir, exeName + '.old');
  const scriptPath = path.join(app.getPath('temp'), 'vixscr-update-' + Date.now() + '.bat');

  const script = [
    '@echo off',
    'setlocal',
    ':waitloop',
    'tasklist /FI "IMAGENAME eq ' + exeName + '" 2>NUL | find /I "' + exeName + '" >NUL',
    'if not errorlevel 1 (',
    '  timeout /t 1 /nobreak >NUL',
    '  goto waitloop',
    ')',
    'if exist "' + backupPath + '" del /f /q "' + backupPath + '"',
    'if exist "' + currentExePath + '" rename "' + currentExePath + '" "' + exeName + '.old"',
    'move /y "' + downloadedExePath + '" "' + currentExePath + '"',
    'if exist "' + backupPath + '" del /f /q "' + backupPath + '"',
    'start "" "' + currentExePath + '"',
    'del "%~f0"'
  ].join('\r\n');

  fs.writeFileSync(scriptPath, script, 'utf8');
  spawn('cmd.exe', ['/c', scriptPath], {
    detached: true,
    stdio: 'ignore',
    windowsHide: true
  }).unref();

  app.quit();
}

// Helper function to check if a URL belongs to TMDB
function isTmdbUrl(urlString) {
  try {
    const parsed = new URL(urlString);
    return (
      parsed.hostname === 'themoviedb.org' ||
      parsed.hostname.endsWith('.themoviedb.org') ||
      parsed.hostname === 'tmdb.org' ||
      parsed.hostname.endsWith('.tmdb.org')
    );
  } catch (err) {
    return false;
  }
}

// Custom protocol used to deep-link straight into a title, e.g.
// VixScr.exe vixscr://1726  or  VixScr.exe vixscr://open/1726
// A bare numeric argument (VixScr.exe 1726) is also accepted.
const PROTOCOL = 'vixscr';

function extractTmdbId(argv) {
  for (const arg of argv) {
    if (!arg) continue;
    const protoMatch = arg.match(/^vixscr:\/\/(?:open\/)?(\d+)/i);
    if (protoMatch) return protoMatch[1];
    if (/^\d+$/.test(arg.trim())) return arg.trim();
  }
  return null;
}

// Arguments passed to the app itself (excludes the exe path, and the app
// path when running unpackaged via `electron .`).
function getLaunchArgs(argv) {
  return app.isPackaged ? argv.slice(1) : argv.slice(2);
}

let mainWindow = null;
let pendingTmdbId = null;

function sendTmdbIdToWindow(tmdbId) {
  if (!mainWindow || !tmdbId) return;
  mainWindow.webContents.send('open-tmdb-id', tmdbId);
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1920,
    height: 1080,
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      nodeIntegration: true,
      contextIsolation: false,
      webSecurity: false
    }
  });

  mainWindow.maximize();

  // Spoof Chrome User-Agent
  const customUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  mainWindow.webContents.setUserAgent(customUserAgent);

  // Strip blocking headers to allow embedding
  session.defaultSession.webRequest.onHeadersReceived((details, callback) => {
    const responseHeaders = { ...details.responseHeaders };

    delete responseHeaders['x-frame-options'];
    delete responseHeaders['X-Frame-Options'];
    delete responseHeaders['content-security-policy'];
    delete responseHeaders['Content-Security-Policy'];

    callback({
      cancel: false,
      responseHeaders: responseHeaders
    });
  });

  // Show a tiny instant-loading screen first (no network/adblocker/tmdb
  // work needed to paint this), then swap to the real app once it's ready.
  // This gives immediate visual feedback instead of a blank/frozen window
  // while index.html's scripts and the TMDB catalogue load.
  let swappedToApp = false;
  mainWindow.loadFile('loading.html');

  function swapToRealApp() {
    if (swappedToApp) return;
    swappedToApp = true;
    mainWindow.webContents.once('did-finish-load', () => {
      if (pendingTmdbId) {
        sendTmdbIdToWindow(pendingTmdbId);
        pendingTmdbId = null;
      }
    });
    mainWindow.loadFile('index.html');
  }

  mainWindow.webContents.once('did-finish-load', () => {
    // Give the loading screen a brief moment on screen so it never just
    // flashes, then move on to the real app. The heavy lifting (adblocker
    // init, protocol registration) already runs in parallel in
    // app.whenReady() below, so this isn't blocked by that work.
    setTimeout(swapToRealApp, 400);
  });
}

// Enforce a single running instance so that launching the app again with a
// new TMDB id (e.g. from a protocol click) can hand the id to the existing
// window instead of silently doing nothing.
const gotSingleInstanceLock = app.requestSingleInstanceLock();

if (!gotSingleInstanceLock) {
  app.quit();
} else {
  app.on('second-instance', (event, argv) => {
    const tmdbId = extractTmdbId(getLaunchArgs(argv));
    if (mainWindow) {
      if (mainWindow.isMinimized()) mainWindow.restore();
      if (!mainWindow.isVisible()) mainWindow.show();
      mainWindow.focus();
      if (tmdbId) sendTmdbIdToWindow(tmdbId);
    }
  });
}

app.whenReady().then(async () => {
  // Global Handler: Catch window.open() & target="_blank" across main window & iframes
  app.on('web-contents-created', (event, contents) => {
    contents.setWindowOpenHandler(({ url }) => {
      if (isTmdbUrl(url)) {
        shell.openExternal(url); // Opens TMDB link in default browser
      }
      return { action: 'deny' }; // Blocks all other popups/tabs
    });

    // Block legacy webview creation
    contents.on('will-attach-webview', (embedEvent) => {
      embedEvent.preventDefault();
    });
  });

  // Enable Ghostery Adblocker
  try {
    const blocker = await ElectronBlocker.fromPrebuiltAdsAndTracking(fetch);
    blocker.enableBlockingInSession(session.defaultSession);
  } catch (err) {
    console.error('Failed to load adblocker:', err);
  }

  // Register as the vixscr:// protocol handler so Windows can launch/focus
  // the app with a deep link like vixscr://1726.
  if (!app.isDefaultProtocolClient(PROTOCOL)) {
    app.setAsDefaultProtocolClient(PROTOCOL);
  }

  // Capture a TMDB id passed on the very first launch of the app.
  pendingTmdbId = extractTmdbId(getLaunchArgs(process.argv));

  createWindow();

  // Silent update check on every launch; result is pushed to the renderer
  // so Settings can show a "new version available" notice.
  checkForUpdate()
    .then(result => {
      if (mainWindow) mainWindow.webContents.send('update-check-result', result);
    })
    .catch(err => {
      if (mainWindow) mainWindow.webContents.send('update-check-result', { error: err.message });
    });

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

// macOS deep-link support (harmless no-op on Windows/Linux).
app.on('open-url', (event, url) => {
  event.preventDefault();
  const tmdbId = extractTmdbId([url]);
  if (!tmdbId) return;
  if (mainWindow) {
    sendTmdbIdToWindow(tmdbId);
  } else {
    pendingTmdbId = tmdbId;
  }
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});

// ── Update IPC surface used by the Settings panel ──────────────────
ipcMain.handle('update:check', async () => {
  try {
    return await checkForUpdate();
  } catch (err) {
    return { error: err.message };
  }
});

ipcMain.handle('update:apply', async (event, exeName) => {
  try {
    const downloadedPath = await downloadUpdate(exeName, (fraction) => {
      if (mainWindow) mainWindow.webContents.send('update-download-progress', fraction);
    });
    applyUpdateAndRestart(downloadedPath);
    return { ok: true };
  } catch (err) {
    return { ok: false, error: err.message };
  }
});