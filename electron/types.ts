export type MediaCategory = 'all' | 'movie' | 'series' | 'anime' | 'short' | 'ai-short' | 'live';

export interface Episode {
  name: string;
  url: string;
  sourceId?: string;
  headers?: Record<string, string>;
}

export interface PlayLine {
  name: string;
  episodes: Episode[];
}

export interface MediaVariant {
  id: string;
  sourceId: string;
  sourceName: string;
}

export interface MediaItem {
  id: string;
  sourceId: string;
  sourceName: string;
  title: string;
  poster: string;
  backdrop?: string;
  year?: string;
  remarks?: string;
  category: MediaCategory;
  summary?: string;
  actors?: string;
  director?: string;
  area?: string;
  playLines?: PlayLine[];
  quality?: string;
  alternatives?: MediaVariant[];
}

export interface CmsSource {
  id: string;
  name: string;
  type: 'cms' | 'spider';
  api?: string;
  enabled: boolean;
  searchable: boolean;
  categories?: string[];
  headers?: Record<string, string>;
  script?: string;
  scriptUrl?: string;
  ruleConfig?: Record<string, unknown>;
}

export interface PlaybackResolution {
  url: string;
  headers?: Record<string, string>;
}

export interface LiveChannel {
  id: string;
  sourceId: string;
  sourceName: string;
  name: string;
  group: string;
  url: string;
  urls?: string[];
  logo?: string;
  tvgId?: string;
}

export interface DanmakuProvider {
  id: string;
  name: string;
  type: 'bilibili' | 'dandanplay';
  api?: string;
  enabled: boolean;
}

export interface DanmakuComment {
  text: string;
  time: number;
  mode: 0 | 1 | 2;
  color: string;
  source: string;
}

export interface DanmakuMatch {
  providerId: string;
  providerName: string;
  title: string;
  episode: string;
  count: number;
}

export interface DanmakuResponse {
  comments: DanmakuComment[];
  matches: DanmakuMatch[];
  failures: Array<{ providerId: string; providerName: string; message: string }>;
  elapsedMs: number;
}

export interface ImportResult {
  importedSources: number;
  importedLives: number;
  failures: string[];
  settings: AppSettings;
}

export interface SearchResponse {
  items: MediaItem[];
  failures: Array<{ sourceId: string; sourceName: string; message: string }>;
  elapsedMs: number;
}

export interface HistoryItem extends MediaItem {
  lineName?: string;
  episodeName?: string;
  progress: number;
  duration: number;
  watchedAt: number;
}

export interface LibraryState {
  favorites: MediaItem[];
  history: HistoryItem[];
}

export interface AppSettings {
  sources: CmsSource[];
  liveChannels: LiveChannel[];
  danmakuProviders: DanmakuProvider[];
  adFiltering: boolean;
  qualityPreference: 'auto' | 'highest' | '1080p' | '720p';
  proxyPort: number;
  proxyBaseUrl?: string;
}
