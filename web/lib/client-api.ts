'use client';

import type {
  AppSettings, CmsSource, ImportResult, LibraryState, LumenApi, LiveChannel,
  MediaCategory, MediaItem, SearchResponse,
} from '../../src/types';

const SETTINGS_KEY = 'videoget.settings.v1';
const LIBRARY_KEY = 'videoget.library.v1';
const defaultSources: CmsSource[] = [
  { id: 'builtin-line-a', name: '默认线路 A', type: 'cms', api: 'https://caiji.moduapi.cc/api.php/provide/vod/', enabled: true, searchable: true },
  { id: 'builtin-line-b', name: '默认线路 B', type: 'cms', api: 'https://jszyapi.com/api.php/provide/vod/', enabled: true, searchable: true },
];
const defaultSettings: AppSettings = {
  sources: defaultSources,
  liveChannels: [],
  qualityPreference: 'highest',
  proxyPort: 0,
  proxyBaseUrl: '/api/proxy',
};
const emptyLibrary: LibraryState = { favorites: [], history: [] };

function readValue<T>(key: string, fallback: T): T {
  try {
    const value = window.localStorage.getItem(key);
    return value ? { ...fallback, ...JSON.parse(value) } : structuredClone(fallback);
  } catch {
    return structuredClone(fallback);
  }
}

function settings(): AppSettings {
  const value = readValue(SETTINGS_KEY, defaultSettings);
  return { ...value, sources: value.sources?.length ? value.sources : structuredClone(defaultSources), proxyPort: 0, proxyBaseUrl: '/api/proxy' };
}

function saveSettings(value: AppSettings): AppSettings {
  const next = { ...value, proxyPort: 0, proxyBaseUrl: '/api/proxy' };
  window.localStorage.setItem(SETTINGS_KEY, JSON.stringify(next));
  return next;
}

async function request<T>(path: string, body: unknown): Promise<T> {
  const response = await fetch(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  const payload = await response.json() as T & { error?: string };
  if (!response.ok) throw new Error(payload.error ?? `HTTP ${response.status}`);
  return payload;
}

function mergeImported(current: AppSettings, imported: { sources: CmsSource[]; lives: LiveChannel[]; failures?: string[] }): ImportResult {
  const sources = new Map(current.sources.map((source) => [source.id, source]));
  const sourceCount = sources.size;
  imported.sources.forEach((source) => sources.set(source.id, source));
  const lives = new Map(current.liveChannels.map((channel) => [channel.id, channel]));
  const liveCount = lives.size;
  imported.lives.forEach((channel) => lives.set(channel.id, channel));
  const next = saveSettings({ ...current, sources: [...sources.values()], liveChannels: [...lives.values()] });
  return {
    importedSources: sources.size - sourceCount,
    importedLives: lives.size - liveCount,
    failures: imported.failures ?? [],
    settings: next,
  };
}

export function installWebApi(): void {
  if (typeof window === 'undefined' || window.lumen) return;
  const api: LumenApi = {
    search(query: string, category: MediaCategory) {
      return request<SearchResponse>('/api/search', { query, category, sources: settings().sources });
    },
    detail(sourceId: string, id: string) {
      return request<MediaItem | null>('/api/detail', { sourceId, id, sources: settings().sources });
    },
    resolve(item: MediaItem) {
      return request<MediaItem | null>('/api/resolve', { item, sources: settings().sources });
    },
    async getSettings() { return settings(); },
    async saveSources(sources: CmsSource[]) { return saveSettings({ ...settings(), sources }); },
    async saveQuality(quality: AppSettings['qualityPreference']) { return saveSettings({ ...settings(), qualityPreference: quality }); },
    async importTvBox(config: unknown) {
      return mergeImported(settings(), await request('/api/import', { config }));
    },
    async importContent(content: string, name: string) {
      return mergeImported(settings(), await request('/api/import', { content, name }));
    },
    async importUrl(url: string) {
      return mergeImported(settings(), await request('/api/import-url', { url }));
    },
    async importIptvCatalog() {
      return mergeImported(settings(), await request('/api/iptv', {}));
    },
    testSource(source: CmsSource) {
      return request('/api/source-test', { source });
    },
    async getLibrary() { return readValue(LIBRARY_KEY, emptyLibrary); },
    async saveLibrary(library: LibraryState) {
      window.localStorage.setItem(LIBRARY_KEY, JSON.stringify(library));
      return library;
    },
    async openExternal(url: string) { window.open(url, '_blank', 'noopener,noreferrer'); },
    minimize() {},
    maximize() {},
    close() {},
    onMaximizeChange() { return () => undefined; },
  };
  window.lumen = api;
}
