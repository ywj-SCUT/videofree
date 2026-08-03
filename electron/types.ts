export type MediaCategory = 'all' | 'movie' | 'series' | 'anime' | 'short' | 'ai-short' | 'live';

export interface Episode {
  name: string;
  url: string;
}

export interface PlayLine {
  name: string;
  episodes: Episode[];
}

export interface MediaItem {
  id: string;
  sourceId: string;
  sourceName: string;
  title: string;
  poster: string;
  year?: string;
  remarks?: string;
  category: MediaCategory;
  summary?: string;
  actors?: string;
  director?: string;
  area?: string;
  playLines?: PlayLine[];
  quality?: string;
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
}

export interface LiveChannel {
  id: string;
  name: string;
  group: string;
  url: string;
  logo?: string;
}

export interface SearchResponse {
  items: MediaItem[];
  failures: Array<{ sourceId: string; sourceName: string; message: string }>;
  elapsedMs: number;
}

export interface LibraryState {
  favorites: MediaItem[];
  history: Array<MediaItem & { episodeName?: string; progress: number; duration: number; watchedAt: number }>;
}

export interface AppSettings {
  sources: CmsSource[];
  liveChannels: LiveChannel[];
  qualityPreference: 'auto' | 'highest' | '1080p' | '720p';
  proxyPort: number;
}
