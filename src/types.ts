export type MediaCategory = 'all' | 'movie' | 'series' | 'anime' | 'short' | 'ai-short' | 'live';
export interface Episode { name: string; url: string }
export interface PlayLine { name: string; episodes: Episode[] }
export interface MediaVariant { id: string; sourceId: string; sourceName: string }
export interface MediaItem {
  id: string; sourceId: string; sourceName: string; title: string; poster: string;
  backdrop?: string;
  year?: string; remarks?: string; category: MediaCategory; summary?: string;
  actors?: string; director?: string; area?: string; playLines?: PlayLine[]; quality?: string;
  alternatives?: MediaVariant[];
}
export interface CmsSource {
  id: string; name: string; type: 'cms' | 'spider'; api?: string; enabled: boolean;
  searchable: boolean; categories?: string[]; headers?: Record<string, string>; script?: string;
}
export interface LiveChannel {
  id: string; sourceId: string; sourceName: string; name: string; group: string;
  url: string; urls?: string[]; logo?: string; tvgId?: string;
}
export interface ImportResult { importedSources: number; importedLives: number; failures: string[]; settings: AppSettings }
export interface SearchResponse { items: MediaItem[]; failures: Array<{ sourceId: string; sourceName: string; message: string }>; elapsedMs: number }
export interface HistoryItem extends MediaItem {
  lineName?: string; episodeName?: string; progress: number; duration: number; watchedAt: number;
}
export interface LibraryState {
  favorites: MediaItem[];
  history: HistoryItem[];
}
export interface AppSettings {
  sources: CmsSource[]; liveChannels: LiveChannel[];
  qualityPreference: 'auto' | 'highest' | '1080p' | '720p'; proxyPort: number; proxyBaseUrl?: string;
}
export interface LumenApi {
  search(query: string, category: MediaCategory): Promise<SearchResponse>;
  detail(sourceId: string, id: string): Promise<MediaItem | null>;
  resolve(item: MediaItem): Promise<MediaItem | null>;
  getSettings(): Promise<AppSettings>;
  saveSources(sources: CmsSource[]): Promise<AppSettings>;
  saveQuality(quality: AppSettings['qualityPreference']): Promise<AppSettings>;
  importTvBox(config: unknown): Promise<ImportResult>;
  importContent(content: string, name: string): Promise<ImportResult>;
  importUrl(url: string): Promise<ImportResult>;
  testSource(source: CmsSource): Promise<{ ok: boolean; latencyMs: number; message: string }>;
  getLibrary(): Promise<LibraryState>;
  saveLibrary(library: LibraryState): Promise<LibraryState>;
  openExternal(url: string): Promise<unknown>;
  minimize(): void; maximize(): void; close(): void;
  onMaximizeChange(callback: (maximized: boolean) => void): () => void;
}
