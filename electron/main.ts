import { app, BrowserWindow, ipcMain, shell } from 'electron';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { aggregateSearch, getDetail, importTvBox, resolveMedia, resolvePlayback, testSource } from './source-engine.js';
import { aggregateDanmaku } from './danmaku-engine.js';
import { fetchRemoteText } from './net-client.js';
import { startProxyServer } from './proxy-server.js';
import { Storage } from './storage.js';
import type { CmsSource, ImportResult, LibraryState, MediaCategory } from './types.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const isAutomationRun = process.argv.some((argument) => argument.startsWith('--remote-debugging-port='));
if (isAutomationRun) {
  const userDataArgument = process.argv.find((argument) => argument.startsWith('--user-data-dir='));
  const userDataPath = userDataArgument?.slice('--user-data-dir='.length)
    || (process.env.APPDATA ? path.join(process.env.APPDATA, 'VideoGET') : '');
  if (userDataPath) app.setPath('userData', path.resolve(userDataPath));
}
let mainWindow: BrowserWindow | null = null;
let proxy: Awaited<ReturnType<typeof startProxyServer>> | null = null;
const storage = new Storage();

async function applyTvBoxImport(config: unknown): Promise<ImportResult> {
  const imported = importTvBox(config);
  const settings = storage.getSettings(proxy?.port ?? 0);
  const sourcesById = new Map(settings.sources.map((source) => [source.id, source]));
  imported.sources.forEach((source) => sourcesById.set(source.id, source));
  await storage.updateSettings({ sources: [...sourcesById.values()] });
  return {
    importedSources: imported.sources.length,
    failures: [],
    settings: storage.getSettings(proxy?.port ?? 0),
  };
}

async function applyImportedContent(content: string): Promise<ImportResult> {
  const trimmed = content.trim();
  if (!trimmed) throw new Error('导入内容为空');
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    return applyTvBoxImport(JSON.parse(trimmed));
  }
  throw new Error('仅支持 JSON 格式的 TVBox 点播配置');
}

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
  ipcMain.handle('settings:danmaku-providers', async (_event, danmakuProviders) => {
    await storage.updateSettings({ danmakuProviders });
    return storage.getSettings(proxy?.port ?? 0);
  });
  ipcMain.handle('settings:ad-filtering', async (_event, adFiltering: boolean) => {
    await storage.updateSettings({ adFiltering });
    return storage.getSettings(proxy?.port ?? 0);
  });
  ipcMain.handle('settings:import-tvbox', (_event, config: unknown) => applyTvBoxImport(config));
  ipcMain.handle('settings:import-content', (_event, content: string) => applyImportedContent(content));
  ipcMain.handle('settings:import-url', async (_event, url: string) => {
    const content = await fetchRemoteText(url);
    return applyImportedContent(content);
  });
  ipcMain.handle('settings:test-source', (_event, source: CmsSource) => testSource(source));
  ipcMain.handle('media:search', async (_event, query: string, category: MediaCategory, page = 1) => {
    const settings = storage.getSettings(proxy?.port ?? 0);
    return aggregateSearch(settings.sources, query, category, page);
  });
  ipcMain.handle('media:detail', async (_event, sourceId: string, id: string) => {
    const settings = storage.getSettings(proxy?.port ?? 0);
    return getDetail(settings.sources, sourceId, id);
  });
  ipcMain.handle('media:resolve', async (_event, item) => {
    const settings = storage.getSettings(proxy?.port ?? 0);
    return resolveMedia(settings.sources, item);
  });
  ipcMain.handle('media:play', async (_event, sourceId: string, token: string) => {
    const settings = storage.getSettings(proxy?.port ?? 0);
    return resolvePlayback(settings.sources, sourceId, token);
  });
  ipcMain.handle('media:danmaku', async (_event, title: string, episodeName: string) => {
    const settings = storage.getSettings(proxy?.port ?? 0);
    return aggregateDanmaku(settings.danmakuProviders, title, episodeName);
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
