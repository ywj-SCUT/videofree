'use client';

import type {
  AppSettings, CmsSource, DanmakuProvider, ImportResult, LibraryState, LumenApi,
  MediaCategory, MediaItem, SearchResponse,
} from '../../src/types';

const SETTINGS_KEY = 'videoget.settings.v1';
const LIBRARY_KEY = 'videoget.library.v1';
const defaultSources: CmsSource[] = [
  { id: 'builtin-short-tikhub-tiktok', name: 'TikTok 推荐', type: 'short-api', api: 'https://api.tikhub.io', provider: 'tikhub-tiktok', region: 'US', enabled: false, searchable: true },
  { id: 'builtin-short-douyin', name: '抖音推荐', type: 'short-api', api: 'https://api.tikhub.io', provider: 'tikhub-douyin', region: 'CN', enabled: false, searchable: true },
  { id: 'builtin-short-youtube', name: 'YouTube Shorts', type: 'short-api', api: 'https://api.tikhub.io', provider: 'tikhub-youtube', region: 'CN', enabled: false, searchable: true },
  { id: 'builtin-line-a', name: '默认线路 A', type: 'cms', api: 'https://caiji.moduapi.cc/api.php/provide/vod/', enabled: true, searchable: true },
  { id: 'builtin-line-b', name: '默认线路 B', type: 'cms', api: 'https://jszyapi.com/api.php/provide/vod/', enabled: true, searchable: true },
];
const defaultSettings: AppSettings = {
  sources: defaultSources,
  danmakuProviders: [{ id: 'bilibili', name: 'Bilibili 弹幕', type: 'bilibili', enabled: true }],
  adFiltering: true,
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
  const persisted = new Map((value.sources ?? []).map((source) => [source.id, source]));
  const managed = defaultSources
    .filter((source) => source.id.startsWith('builtin-'))
    .map((source) => ({ ...source, ...persisted.get(source.id) }));
  const custom = (value.sources ?? []).filter((source) => !source.id.startsWith('builtin-'));
  return {
    sources: [...managed, ...custom],
    danmakuProviders: value.danmakuProviders ?? structuredClone(defaultSettings.danmakuProviders),
    adFiltering: value.adFiltering ?? true,
    qualityPreference: value.qualityPreference ?? 'highest',
    proxyPort: 0,
    proxyBaseUrl: '/api/proxy',
  };
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

function mergeImported(current: AppSettings, imported: { sources: CmsSource[]; failures?: string[] }): ImportResult {
  const sources = new Map(current.sources.map((source) => [source.id, source]));
  const sourceCount = sources.size;
  imported.sources.forEach((source) => sources.set(source.id, source));
  const next = saveSettings({ ...current, sources: [...sources.values()] });
  return {
    importedSources: sources.size - sourceCount,
    failures: imported.failures ?? [],
    settings: next,
  };
}

export function installWebApi(): void {
  if (typeof window === 'undefined' || window.lumen) return;
  const api: LumenApi = {
    search(query: string, category: MediaCategory, page = 1) {
      return request<SearchResponse>('/api/search', { query, category, page, sources: settings().sources });
    },
    detail(sourceId: string, id: string) {
      return request<MediaItem | null>('/api/detail', { sourceId, id, sources: settings().sources });
    },
    resolve(item: MediaItem) {
      return request<MediaItem | null>('/api/resolve', { item, sources: settings().sources });
    },
    play(sourceId: string, token: string) {
      return request('/api/play', { sourceId, token, sources: settings().sources });
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
    async saveDanmakuProviders(danmakuProviders: DanmakuProvider[]) { return saveSettings({ ...settings(), danmakuProviders }); },
    async saveAdFiltering(adFiltering: boolean) { return saveSettings({ ...settings(), adFiltering }); },
    danmaku(title: string, episodeName: string) {
      return request('/api/danmaku', { title, episodeName, providers: settings().danmakuProviders });
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
