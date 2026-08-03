import { app, BrowserWindow, ipcMain, shell } from 'electron';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { aggregateSearch, getDetail, importTvBox, testSource } from './source-engine.js';
import { startProxyServer } from './proxy-server.js';
import { Storage } from './storage.js';
import type { CmsSource, LibraryState, MediaCategory } from './types.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
let mainWindow: BrowserWindow | null = null;
let proxy: Awaited<ReturnType<typeof startProxyServer>> | null = null;
const storage = new Storage();

function createWindow(): void {
  mainWindow = new BrowserWindow({
    width: 1420,
    height: 900,
    minWidth: 1050,
    minHeight: 680,
    backgroundColor: '#0b0b0d',
    title: 'VideoGET',
    show: false,
    titleBarStyle: 'hidden',
    titleBarOverlay: {
      color: '#00000000',
      symbolColor: '#b8b8be',
      height: 44,
    },
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
    },
  });
  const devUrl = process.env.VITE_DEV_SERVER_URL;
  if (devUrl) void mainWindow.loadURL(devUrl);
  else void mainWindow.loadFile(path.join(__dirname, '..', 'dist', 'index.html'));
  mainWindow.once('ready-to-show', () => mainWindow?.show());
  mainWindow.on('maximize', () => mainWindow?.webContents.send('window:maximized', true));
  mainWindow.on('unmaximize', () => mainWindow?.webContents.send('window:maximized', false));
  mainWindow.on('closed', () => { mainWindow = null; });
}

function registerIpc(): void {
  ipcMain.handle('settings:get', () => storage.getSettings(proxy?.port ?? 0));
  ipcMain.handle('settings:sources', async (_event, sources: CmsSource[]) => {
    await storage.updateSettings({ sources });
    return storage.getSettings(proxy?.port ?? 0);
  });
  ipcMain.handle('settings:quality', async (_event, quality) => {
    await storage.updateSettings({ qualityPreference: quality });
    return storage.getSettings(proxy?.port ?? 0);
  });
  ipcMain.handle('settings:import-tvbox', async (_event, config: unknown) => {
    const imported = importTvBox(config);
    const settings = storage.getSettings(proxy?.port ?? 0);
    const sourcesById = new Map(settings.sources.map((source) => [source.id, source]));
    imported.sources.forEach((source) => sourcesById.set(source.id, source));
    await storage.updateSettings({
      sources: [...sourcesById.values()],
      liveChannels: [...settings.liveChannels, ...imported.lives],
    });
    return { importedSources: imported.sources.length, importedLives: imported.lives.length, settings: storage.getSettings(proxy?.port ?? 0) };
  });
  ipcMain.handle('settings:test-source', (_event, source: CmsSource) => testSource(source));
  ipcMain.handle('media:search', async (_event, query: string, category: MediaCategory) => {
    const settings = storage.getSettings(proxy?.port ?? 0);
    return aggregateSearch(settings.sources, query, category);
  });
  ipcMain.handle('media:detail', async (_event, sourceId: string, id: string) => {
    const settings = storage.getSettings(proxy?.port ?? 0);
    return getDetail(settings.sources, sourceId, id);
  });
  ipcMain.handle('library:get', () => storage.getLibrary());
  ipcMain.handle('library:save', async (_event, library: LibraryState) => {
    await storage.updateLibrary(library);
    return storage.getLibrary();
  });
  ipcMain.handle('system:open-external', (_event, url: string) => {
    if (/^https?:\/\//i.test(url)) return shell.openExternal(url);
    return false;
  });
  ipcMain.on('window:minimize', () => mainWindow?.minimize());
  ipcMain.on('window:maximize', () => mainWindow?.isMaximized() ? mainWindow.unmaximize() : mainWindow?.maximize());
  ipcMain.on('window:close', () => mainWindow?.close());
}

app.whenReady().then(async () => {
  app.setAppUserModelId('com.videoget.desktop');
  await storage.init();
  proxy = await startProxyServer(path.join(app.getPath('userData'), 'image-cache'));
  registerIpc();
  createWindow();
  app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
});

app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
app.on('before-quit', () => { if (proxy) void proxy.close(); });
