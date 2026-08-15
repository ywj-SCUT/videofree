import { contextBridge, ipcRenderer } from 'electron';
import type { AppSettings, CmsSource, DanmakuProvider, LibraryState, MediaCategory } from './types.js';

const api = {
  search: (query: string, category: MediaCategory, page = 1) => ipcRenderer.invoke('media:search', query, category, page),
  detail: (sourceId: string, id: string) => ipcRenderer.invoke('media:detail', sourceId, id),
  resolve: (item: unknown) => ipcRenderer.invoke('media:resolve', item),
  play: (sourceId: string, token: string) => ipcRenderer.invoke('media:play', sourceId, token),
  getSettings: (): Promise<AppSettings> => ipcRenderer.invoke('settings:get'),
  saveSources: (sources: CmsSource[]) => ipcRenderer.invoke('settings:sources', sources),
  saveQuality: (quality: AppSettings['qualityPreference']) => ipcRenderer.invoke('settings:quality', quality),
  importTvBox: (config: unknown) => ipcRenderer.invoke('settings:import-tvbox', config),
  importContent: (content: string, name: string) => ipcRenderer.invoke('settings:import-content', content, name),
  importUrl: (url: string) => ipcRenderer.invoke('settings:import-url', url),
  saveDanmakuProviders: (providers: DanmakuProvider[]) => ipcRenderer.invoke('settings:danmaku-providers', providers),
  saveAdFiltering: (enabled: boolean) => ipcRenderer.invoke('settings:ad-filtering', enabled),
  danmaku: (title: string, episodeName: string) => ipcRenderer.invoke('media:danmaku', title, episodeName),
  testSource: (source: CmsSource) => ipcRenderer.invoke('settings:test-source', source),
  getLibrary: (): Promise<LibraryState> => ipcRenderer.invoke('library:get'),
  saveLibrary: (library: LibraryState) => ipcRenderer.invoke('library:save', library),
  openExternal: (url: string) => ipcRenderer.invoke('system:open-external', url),
  getCacheStats: () => ipcRenderer.invoke('cache:stats'),
  clearCache: () => ipcRenderer.invoke('cache:clear'),
  startPrefetch: (url: string) => ipcRenderer.invoke('prefetch:start', url),
  stopPrefetch: () => ipcRenderer.invoke('prefetch:stop'),
  getPrefetchStatus: () => ipcRenderer.invoke('prefetch:status'),
  onPrefetchProgress: (callback: (progress: { total: number; cached: number; fetched: number; failed: number; bytes: number; done: boolean; status: string }) => void) => {
    ipcRenderer.send('prefetch:progress-listener');
    const handler = (_event: Electron.IpcRendererEvent, progress: { total: number; cached: number; fetched: number; failed: number; bytes: number; done: boolean; status: string }) => callback(progress);
    ipcRenderer.on('prefetch:progress', handler);
    return () => ipcRenderer.removeListener('prefetch:progress', handler);
  },
  minimize: () => ipcRenderer.send('window:minimize'),
  maximize: () => ipcRenderer.send('window:maximize'),
  close: () => ipcRenderer.send('window:close'),
  onMaximizeChange: (callback: (maximized: boolean) => void) => {
    const handler = (_event: Electron.IpcRendererEvent, value: boolean) => callback(value);
    ipcRenderer.on('window:maximized', handler);
    return () => ipcRenderer.removeListener('window:maximized', handler);
  },
};

contextBridge.exposeInMainWorld('lumen', api);

