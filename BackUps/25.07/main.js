const { app, BrowserWindow, session, Menu } = require('electron');
const path = require('path');
const { ElectronBlocker } = require('@ghostery/adblocker-electron');
const fetch = require('cross-fetch');

// 1. Remove the default Electron application menu bar completely
Menu.setApplicationMenu(null);

function createWindow() {
  const mainWindow = new BrowserWindow({
    width: 1920,
    height: 1080,
    autoHideMenuBar: true,
    webPreferences: {
      nodeIntegration: true,
      contextIsolation: false,
      webSecurity: false
    }
  });

  // Maximize the window to fill the screen on launch
  mainWindow.maximize();

  // Block popups from the main window
  mainWindow.webContents.setWindowOpenHandler(() => {
    return { action: 'deny' };
  });

  // Spoof Chrome User-Agent
  const customUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  mainWindow.webContents.setUserAgent(customUserAgent);

  // Strip blocking response headers
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

  // Load your UI
  mainWindow.loadFile('index.html');
}

app.whenReady().then(async () => {
  // Block popups across frames
  app.on('web-contents-created', (event, contents) => {
    contents.setWindowOpenHandler(() => {
      return { action: 'deny' };
    });
  });

  // Initialize Adblocker
  try {
    const blocker = await ElectronBlocker.fromPrebuiltAdsAndTracking(fetch);
    blocker.enableBlockingInSession(session.defaultSession);
  } catch (err) {
    console.error('Failed to load adblocker:', err);
  }

  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});