'use client';

import type {
  AppSettings, CmsSource, DanmakuProvider, ImportResult, LibraryState, LumenApi,
  MediaCategory, MediaItem, SearchResponse,
} from '../../src/types';

const SETTINGS_KEY = 'videoget.settings.v1';
const PLAYBACK_TUNING_KEY = 'videoget.playback-tuning.v2';
const MANAGED_SOURCES_KEY = 'videoget.managed-sources.v4';
const LIBRARY_KEY = 'videoget.library.v1';
const defaultSources: CmsSource[] = [
  { id: 'builtin-short-tikhub-tiktok', name: 'TikTok 推荐', type: 'short-api', api: 'https://api.tikhub.io', provider: 'tikhub-tiktok', region: 'US', enabled: false, searchable: true },
  { id: 'builtin-short-douyin', name: '抖音推荐', type: 'short-api', api: 'https://api.tikhub.io', provider: 'tikhub-douyin', region: 'CN', enabled: false, searchable: true },
  { id: 'builtin-short-youtube', name: 'YouTube Shorts', type: 'short-api', api: 'https://api.tikhub.io', provider: 'tikhub-youtube', region: 'CN', enabled: false, searchable: true },
  { id: 'builtin-line-a', name: '默认线路 A', type: 'cms', api: 'https://caiji.moduapi.cc/api.php/provide/vod/', enabled: true, searchable: true },
  { id: 'builtin-line-b', name: '默认线路 B', type: 'cms', api: 'https://jszyapi.com/api.php/provide/vod/', enabled: true, searchable: true },
  { id: 'builtin-line-c', name: '默认线路 C', type: 'cms', api: 'https://cj.lziapi.com/api.php/provide/vod/', enabled: true, searchable: true },
  { id: 'builtin-line-d', name: '默认线路 D', type: 'cms', api: 'https://api.ukuapi.com/api.php/provide/vod/', enabled: true, searchable: true },
  { id: 'builtin-line-e', name: '默认线路 E', type: 'cms', api: 'https://api.wujinapi.com/api.php/provide/vod/', enabled: true, searchable: true },
  { id: 'builtin-line-f', name: '默认线路 F', type: 'cms', api: 'https://cj.rycjapi.com/api.php/provide/vod/', enabled: true, searchable: true },
  { id: 'builtin-line-g', name: '默认线路 G', type: 'cms', api: 'https://cj.ffzyapi.com/api.php/provide/vod/', enabled: true, searchable: true },
  { id: 'builtin-line-h', name: '默认线路 H', type: 'cms', api: 'https://bfzyapi.com/api.php/provide/vod/', enabled: true, searchable: true },
  { id: 'builtin-line-i', name: '默认线路 I', type: 'cms', api: 'https://ikunzyapi.com/api.php/provide/vod/', enabled: true, searchable: true },
  { id: 'builtin-line-j', name: '默认线路 J', type: 'cms', api: 'https://api.guangsuapi.com/api.php/provide/vod/from/gsm3u8', enabled: true, searchable: true },
  { id: 'builtin-line-k', name: '默认线路 K', type: 'cms', api: 'https://jyzyapi.com/provide/vod/from/jinyingm3u8', enabled: true, searchable: true },
  { id: 'builtin-line-l', name: '默认线路 L', type: 'cms', api: 'https://360zy.com/api.php/provide/vod', enabled: true, searchable: true },
  { id: 'builtin-line-m', name: '默认线路 M', type: 'cms', api: 'https://iqiyizyapi.com/api.php/provide/vod', enabled: true, searchable: true },
];
const defaultSettings: AppSettings = {
  sources: defaultSources,
  danmakuProviders: [{ id: 'bilibili', name: 'Bilibili 弹幕', type: 'bilibili', enabled: true }],
  adFiltering: true,
  qualityPreference: 'auto',
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
  const needsPlaybackMigration = window.localStorage.getItem(PLAYBACK_TUNING_KEY) !== '1';
  const needsManagedSourcesMigration = window.localStorage.getItem(MANAGED_SOURCES_KEY) !== '1';
  const persisted = new Map((value.sources ?? []).map((source) => [source.id, source]));
  const managed = defaultSources
    .filter((source) => source.id.startsWith('builtin-'))
    .map((source) => {
      const saved = persisted.get(source.id);
      return {
        ...source,
        enabled: saved?.enabled ?? source.enabled,
        searchable: saved?.searchable ?? source.searchable,
      };
    });
  const custom = (value.sources ?? []).filter((source) => !source.id.startsWith('builtin-'));
  const next: AppSettings = {
    sources: [...managed, ...custom],
    danmakuProviders: value.danmakuProviders ?? structuredClone(defaultSettings.danmakuProviders),
    adFiltering: value.adFiltering ?? true,
    qualityPreference: needsPlaybackMigration && value.qualityPreference === 'highest'
      ? 'auto'
      : value.qualityPreference ?? 'auto',
    proxyPort: 0,
    proxyBaseUrl: '/api/proxy',
  };
  if (needsPlaybackMigration || needsManagedSourcesMigration) {
    window.localStorage.setItem(SETTINGS_KEY, JSON.stringify(next));
    if (needsPlaybackMigration) window.localStorage.setItem(PLAYBACK_TUNING_KEY, '1');
    if (needsManagedSourcesMigration) window.localStorage.setItem(MANAGED_SOURCES_KEY, '1');
  }
  return next;
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
    async routeLines(lines) { return lines; },
    async reportRouteOutcome() {},
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
    async startPrefetch() {},
    async stopPrefetch() {},
    minimize() {},
    maximize() {},
    close() {},
    onMaximizeChange() { return () => undefined; },
  };
  window.lumen = api;
}
