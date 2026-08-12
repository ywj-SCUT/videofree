import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import Artplayer from 'artplayer';
import artplayerPluginDanmuku, { type Result as DanmakuPlugin } from 'artplayer-plugin-danmuku';
import Hls, { ErrorDetails, ErrorTypes } from 'hls.js';
import {
  ArrowDownUp, Captions, CaptionsOff, Check, ChevronDown, Clapperboard, Clock3, Compass, Film,
  Grid2X2, Heart, Info, KeyRound, LibraryBig, LoaderCircle, Maximize2, Minimize2, Minus,
  MonitorPlay, Pause, Play, Plus, Search, Settings, Sparkles, Star, Trash2, Upload, Volume2,
  VolumeX, X,
} from 'lucide-react';
import type { AppSettings, CmsSource, DanmakuProvider, HistoryItem, LibraryState, MediaCategory, MediaItem, SearchResponse } from './types';

type View = 'discover' | 'search' | 'shorts' | 'favorites' | 'history' | 'settings';

const categories: Array<{ value: MediaCategory; label: string }> = [
  { value: 'all', label: '全部' },
  { value: 'movie', label: '电影' },
  { value: 'series', label: '电视剧' },
  { value: 'anime', label: '动漫' },
  { value: 'short', label: '短视频' },
  { value: 'ai-short', label: 'AI 短视频' },
];

const navItems: Array<{ id: View; label: string; icon: typeof Compass }> = [
  { id: 'discover', label: '发现', icon: Compass },
  { id: 'search', label: '搜索', icon: Search },
  { id: 'shorts', label: '短视频', icon: Clapperboard },
  { id: 'favorites', label: '收藏', icon: Heart },
  { id: 'history', label: '观看记录', icon: Clock3 },
];

const emptySettings: AppSettings = { sources: [], danmakuProviders: [], adFiltering: true, qualityPreference: 'auto', proxyPort: 0 };
const emptyLibrary: LibraryState = { favorites: [], history: [] };

type QualityPreference = AppSettings['qualityPreference'];

function levelLabel(level: Hls['levels'][number], index: number): string {
  if (level.height >= 2160) return '4K';
  if (level.height >= 1440) return '2K';
  if (level.height > 0) return `${level.height}P`;
  if (level.bitrate > 0) return `${(level.bitrate / 1_000_000).toFixed(1)} Mbps`;
  return `画质 ${index + 1}`;
}

function preferredLevel(levels: Hls['levels'], preference: QualityPreference): number {
  if (preference === 'auto' || !levels.length) return -1;
  if (preference === 'highest') return levels.reduce((best, level, index) => {
    const bestLevel = levels[best];
    return level.height > bestLevel.height || (level.height === bestLevel.height && level.bitrate > bestLevel.bitrate) ? index : best;
  }, 0);
  const target = preference === '1080p' ? 1080 : 720;
  const candidates = levels
    .map((level, index) => ({ level, index }))
    .filter(({ level }) => level.height > 0 && level.height <= target);
  const pool = candidates.length ? candidates : levels.map((level, index) => ({ level, index }));
  return pool.reduce((best, current) => {
    if (candidates.length) {
      return current.level.height > best.level.height || (current.level.height === best.level.height && current.level.bitrate > best.level.bitrate) ? current : best;
    }
    const currentHeight = current.level.height || Number.MAX_SAFE_INTEGER;
    const bestHeight = best.level.height || Number.MAX_SAFE_INTEGER;
    return currentHeight < bestHeight || (currentHeight === bestHeight && current.level.bitrate < best.level.bitrate) ? current : best;
  }).index;
}

function attachHls(video: HTMLVideoElement, sourceUrl: string, art: Artplayer, preference: QualityPreference, onQuality?: (label: string) => void, lowLatencyMode = false): void {
  if (!Hls.isSupported()) {
    if (video.canPlayType('application/vnd.apple.mpegurl')) video.src = sourceUrl;
    return;
  }
  const hls = new Hls({
    enableWorker: true,
    lowLatencyMode,
    maxBufferLength: 30,
    maxMaxBufferLength: 90,
    maxBufferSize: 96 * 1024 * 1024,
    backBufferLength: 30,
    startFragPrefetch: true,
    fragLoadingMaxRetry: 6,
    fragLoadingRetryDelay: 500,
    fragLoadingTimeOut: 30_000,
    manifestLoadingMaxRetry: 3,
    levelLoadingMaxRetry: 3,
    startLevel: -1,
    capLevelToPlayerSize: preference === 'auto',
    abrEwmaDefaultEstimate: 1_000_000,
    abrBandWidthFactor: 0.9,
    abrBandWidthUpFactor: 0.7,
  });
  let adaptiveCap = -1;
  let networkRecoveryCount = 0;
  let mediaRecoveryCount = 0;
  let stallTimes: number[] = [];

  const adaptiveLabel = () => {
    const active = hls.currentLevel >= 0 ? levelLabel(hls.levels[hls.currentLevel], hls.currentLevel) : '';
    const cap = adaptiveCap >= 0 ? ` / 上限 ${levelLabel(hls.levels[adaptiveCap], adaptiveCap)}` : '';
    return active ? `智能 · ${active}${cap}` : `智能适配${cap}`;
  };
  const enableAdaptiveMode = (cap: number, capToPlayerSize = false) => {
    adaptiveCap = cap;
    hls.capLevelToPlayerSize = capToPlayerSize;
    hls.autoLevelCapping = cap;
    hls.loadLevel = -1;
    onQuality?.(adaptiveLabel());
  };
  const downgradeAfterStalls = () => {
    const current = hls.currentLevel >= 0 ? hls.currentLevel : hls.nextAutoLevel;
    if (current <= 0) return;
    const nextCap = adaptiveCap >= 0 ? Math.min(adaptiveCap, current - 1) : current - 1;
    hls.capLevelToPlayerSize = false;
    hls.autoLevelCapping = nextCap;
    hls.nextAutoLevel = nextCap;
    hls.currentLevel = -1;
    adaptiveCap = nextCap;
    art.notice.show = `网络波动，已自动降至 ${levelLabel(hls.levels[nextCap], nextCap)} 以内`;
    onQuality?.(adaptiveLabel());
  };

  art.hls = hls;
  hls.loadSource(sourceUrl);
  hls.attachMedia(video);
  hls.on(Hls.Events.MANIFEST_PARSED, () => {
    const preferredCap = preferredLevel(hls.levels, preference);
    enableAdaptiveMode(preferredCap, preference === 'auto');
    const choices = [{ html: '自动', level: -1 }, ...hls.levels.map((level, index) => ({ html: levelLabel(level, index), level: index }))];
    const selectedLabel = adaptiveLabel();
    if (art.setting.find('videoget-quality')) art.setting.remove('videoget-quality');
    art.setting.add({
      name: 'videoget-quality',
      html: '画质',
      tooltip: selectedLabel,
      selector: choices.map((choice) => ({ ...choice, default: choice.level === -1 })),
      onSelect(item) {
        const level = Number(item.level);
        if (level < 0) {
          enableAdaptiveMode(preferredCap, preference === 'auto');
        } else {
          adaptiveCap = -1;
          hls.capLevelToPlayerSize = false;
          hls.autoLevelCapping = -1;
          hls.currentLevel = level;
        }
        if (item.$parent?.$tooltip) item.$parent.$tooltip.textContent = String(item.html);
        onQuality?.(level < 0 ? adaptiveLabel() : String(item.html));
        return item.html;
      },
    });
    onQuality?.(selectedLabel);
  });
  hls.on(Hls.Events.LEVEL_SWITCHED, (_event, data) => {
    const label = levelLabel(hls.levels[data.level], data.level);
    onQuality?.(hls.autoLevelEnabled ? `智能 · ${label}` : label);
  });
  hls.on(Hls.Events.FRAG_LOADED, () => {
    networkRecoveryCount = 0;
  });
  hls.on(Hls.Events.ERROR, (_event, data) => {
    if (data.details === ErrorDetails.BUFFER_STALLED_ERROR) {
      const now = Date.now();
      stallTimes = [...stallTimes.filter((time) => now - time < 60_000), now];
      if (stallTimes.length >= 2) {
        stallTimes = [];
        downgradeAfterStalls();
      }
    }
    if (!data.fatal) return;
    if (data.type === ErrorTypes.NETWORK_ERROR && networkRecoveryCount < 2) {
      networkRecoveryCount++;
      downgradeAfterStalls();
      hls.startLoad(video.currentTime);
      art.notice.show = '网络中断，正在续载';
      return;
    }
    if (data.type === ErrorTypes.MEDIA_ERROR && mediaRecoveryCount < 2) {
      mediaRecoveryCount++;
      hls.recoverMediaError();
      art.notice.show = '播放异常，正在恢复';
      return;
    }
    art.notice.show = '当前线路持续加载失败，请切换线路重试';
    hls.stopLoad();
  });
  art.on('destroy', () => hls.destroy());
}

function imageUrl(source: string, proxyPort: number, width: number, height: number): string {
  if (!source || !proxyPort || !/^https?:\/\//i.test(source)) return source;
  const params = new URLSearchParams({ url: source, w: String(width), h: String(height) });
  return `http://127.0.0.1:${proxyPort}/image?${params}`;
}

function streamUrl(settings: AppSettings, source: string, headers?: Record<string, string>): string {
  if (!/^https?:\/\//i.test(source)) return source;
  const adFilter = settings.adFiltering ? '&filterAds=1' : '';
  const requestHeaders = headers && Object.keys(headers).length ? `&headers=${encodeURIComponent(JSON.stringify(headers))}` : '';
  if (settings.proxyBaseUrl) return `${settings.proxyBaseUrl}?url=${encodeURIComponent(source)}${adFilter}${requestHeaders}`;
  return settings.proxyPort > 0 ? `http://127.0.0.1:${settings.proxyPort}/stream?url=${encodeURIComponent(source)}${adFilter}${requestHeaders}` : source;
}

function App() {
  const [view, setView] = useState<View>('discover');
  const [query, setQuery] = useState('');
  const [category, setCategory] = useState<MediaCategory>('all');
  const [items, setItems] = useState<MediaItem[]>([]);
  const [loading, setLoading] = useState(false);
  const [loadingMore, setLoadingMore] = useState(false);
  const [shortHasMore, setShortHasMore] = useState(false);
  const [shortFailures, setShortFailures] = useState<SearchResponse['failures']>([]);
  const [searchMeta, setSearchMeta] = useState({ elapsedMs: 0, failures: 0 });
  const [settings, setSettings] = useState<AppSettings>(emptySettings);
  const [library, setLibrary] = useState<LibraryState>(emptyLibrary);
  const [selected, setSelected] = useState<MediaItem | null>(null);
  const [resume, setResume] = useState<HistoryItem | null>(null);
  const searchTimer = useRef<number>();
  const searchRequest = useRef(0);
  const loadingMoreRef = useRef(false);
  const itemsRef = useRef<MediaItem[]>([]);
  const shortFeedRef = useRef<{ mode: MediaCategory; page: number; hasMore: boolean }>({ mode: 'short', page: 1, hasMore: false });
  const libraryRef = useRef<LibraryState>(emptyLibrary);
  const saveQueue = useRef<Promise<unknown>>(Promise.resolve());

  const searchMedia = useCallback(async (nextQuery: string, nextCategory: MediaCategory) => {
    const requestId = ++searchRequest.current;
    setLoading(true);
    try {
      const response = await window.lumen.search(nextQuery, nextCategory, 1);
      if (requestId !== searchRequest.current) return;
      itemsRef.current = response.items;
      setItems(response.items);
      setSearchMeta({ elapsedMs: response.elapsedMs, failures: response.failures.length });
      const isShortFeed = nextCategory === 'short' || nextCategory === 'ai-short';
      setShortFailures(nextCategory === 'short' ? response.failures : []);
      shortFeedRef.current = { mode: nextCategory, page: response.page, hasMore: isShortFeed && response.hasMore };
      setShortHasMore(isShortFeed && response.hasMore);
    } finally {
      if (requestId === searchRequest.current) setLoading(false);
    }
  }, []);

  const loadMoreShorts = useCallback(async (mode: MediaCategory) => {
    const feed = shortFeedRef.current;
    if (loadingMoreRef.current || feed.mode !== mode || !feed.hasMore) return;
    loadingMoreRef.current = true;
    setLoadingMore(true);
    const requestId = searchRequest.current;
    let page = feed.page;
    let hasMore: boolean = feed.hasMore;
    let fresh: MediaItem[] = [];
    let elapsedMs = 0;
    let failures = 0;
    try {
      const known = new Set(itemsRef.current.map((item) => `${item.sourceId}:${item.id}`));
      for (let attempt = 0; attempt < 4 && hasMore && !fresh.length; attempt += 1) {
        const response = await window.lumen.search('', mode, page + 1);
        if (requestId !== searchRequest.current || shortFeedRef.current.mode !== mode) return;
        page = response.page;
        hasMore = response.hasMore;
        elapsedMs += response.elapsedMs;
        failures += response.failures.length;
        if (mode === 'short' && response.failures.length) {
          setShortFailures((current) => {
            const merged = new Map(current.map((failure) => [failure.sourceId, failure]));
            response.failures.forEach((failure) => merged.set(failure.sourceId, failure));
            return [...merged.values()];
          });
        }
        fresh = response.items.filter((item) => !known.has(`${item.sourceId}:${item.id}`));
      }
      if (fresh.length) {
        const next = [...itemsRef.current, ...fresh];
        itemsRef.current = next;
        setItems(next);
      }
      shortFeedRef.current = { mode, page, hasMore };
      setShortHasMore(hasMore);
      if (elapsedMs) setSearchMeta({ elapsedMs, failures });
    } finally {
      loadingMoreRef.current = false;
      setLoadingMore(false);
    }
  }, []);

  useEffect(() => {
    void Promise.all([window.lumen.getSettings(), window.lumen.getLibrary()]).then(([nextSettings, nextLibrary]) => {
      setSettings(nextSettings);
      setLibrary(nextLibrary);
      libraryRef.current = nextLibrary;
    });
    void searchMedia('', 'all');
  }, [searchMedia]);

  useEffect(() => {
    if (view !== 'search') return;
    window.clearTimeout(searchTimer.current);
    searchTimer.current = window.setTimeout(() => void searchMedia(query, category), 280);
    return () => window.clearTimeout(searchTimer.current);
  }, [query, category, view, searchMedia]);

  const navigate = (next: View) => {
    setView(next);
    if (next === 'shorts') {
      setCategory('short');
      void searchMedia('', 'short');
    }
    if (next === 'discover') {
      setCategory('all');
      void searchMedia('', 'all');
    }
  };

  const openMedia = async (item: MediaItem, historyItem?: HistoryItem) => {
    setLoading(true);
    try {
      const detail = await window.lumen.resolve(item);
      setResume(historyItem ?? null);
      setSelected(detail ?? item);
    } finally {
      setLoading(false);
    }
  };

  const updateLibrary = useCallback((updater: (current: LibraryState) => LibraryState) => {
    const next = updater(libraryRef.current);
    libraryRef.current = next;
    setLibrary(next);
    saveQueue.current = saveQueue.current
      .catch(() => undefined)
      .then(() => window.lumen.saveLibrary(next));
  }, []);

  const toggleFavorite = (item: MediaItem) => {
    updateLibrary((current) => {
      const exists = current.favorites.some((entry) => entry.id === item.id && entry.sourceId === item.sourceId);
      const favorites = exists
        ? current.favorites.filter((entry) => !(entry.id === item.id && entry.sourceId === item.sourceId))
        : [item, ...current.favorites];
      return { ...current, favorites };
    });
  };

  const updateProgress = useCallback((item: MediaItem, progress: number, duration: number, lineName: string, episodeName: string) => {
    updateLibrary((current) => {
      const rest = current.history.filter((entry) => !(entry.id === item.id && entry.sourceId === item.sourceId));
      const historyItem: HistoryItem = { ...item, progress, duration, lineName, episodeName, watchedAt: Date.now() };
      return { ...current, history: [historyItem, ...rest].slice(0, 100) };
    });
  }, [updateLibrary]);

  const removeHistory = (item: MediaItem) => updateLibrary((current) => ({
    ...current,
    history: current.history.filter((entry) => !(entry.id === item.id && entry.sourceId === item.sourceId)),
  }));

  const clearLibrarySection = (section: 'favorites' | 'history') => updateLibrary((current) => ({ ...current, [section]: [] }));

  const favoriteKeys = useMemo(() => new Set(library.favorites.map((item) => `${item.sourceId}:${item.id}`)), [library.favorites]);

  return (
    <div className="app-shell">
      <TitleBar />
      <aside className="sidebar">
        <div className="brand" onClick={() => navigate('discover')}>
          <span className="brand-mark"><img src="./videoget-icon.svg" alt="" /></span>
          <span>VideoGET</span>
        </div>
        <nav>
          {navItems.map(({ id, label, icon: Icon }) => (
            <button key={id} className={view === id ? 'nav-item active' : 'nav-item'} onClick={() => navigate(id)}>
              <Icon size={18} strokeWidth={1.8} /><span>{label}</span>
              {id === 'favorites' && library.favorites.length > 0 && <small>{library.favorites.length}</small>}
              {id === 'history' && library.history.length > 0 && <small>{library.history.length}</small>}
            </button>
          ))}
        </nav>
        <div className="sidebar-spacer" />
        <div className="source-summary">
          <span className="status-dot" />
          <div><strong>{settings.sources.filter((source) => source.enabled).length + 1} 个来源</strong><small>本地代理已就绪</small></div>
        </div>
        <button className={view === 'settings' ? 'nav-item active' : 'nav-item'} onClick={() => navigate('settings')}>
          <Settings size={18} strokeWidth={1.8} /><span>设置</span>
        </button>
      </aside>

      <main className="main-content">
        {view === 'discover' && <Discover items={items} loading={loading} onOpen={openMedia} favoriteKeys={favoriteKeys} onFavorite={toggleFavorite} onSearch={() => navigate('search')} onFavorites={() => navigate('favorites')} proxyPort={settings.proxyPort} />}
        {view === 'search' && (
          <SearchView query={query} setQuery={setQuery} category={category} setCategory={setCategory} items={items} loading={loading}
            meta={searchMeta} onOpen={openMedia} favoriteKeys={favoriteKeys} onFavorite={toggleFavorite} proxyPort={settings.proxyPort} />
        )}
        {view === 'shorts' && <ShortsView items={items} failures={shortFailures} loading={loading} loadingMore={loadingMore} hasMore={shortHasMore} onLoadMore={() => loadMoreShorts(category)} onOpen={openMedia} onConfigure={() => navigate('settings')} onMode={(mode) => { setCategory(mode); void searchMedia('', mode); }} mode={category} favoriteKeys={favoriteKeys} onFavorite={toggleFavorite} settings={settings} />}
        {view === 'favorites' && <LibraryView mode="favorites" items={library.favorites} onOpen={openMedia} onRemove={toggleFavorite} onClear={() => clearLibrarySection('favorites')} proxyPort={settings.proxyPort} />}
        {view === 'history' && <LibraryView mode="history" items={library.history} onOpen={openMedia} onRemove={removeHistory} onClear={() => clearLibrarySection('history')} proxyPort={settings.proxyPort} />}
        {view === 'settings' && <SettingsView settings={settings} onSettings={setSettings} />}
      </main>

      {selected && (
        <PlayerSheet item={selected} settings={settings} isFavorite={favoriteKeys.has(`${selected.sourceId}:${selected.id}`)}
          resume={resume} onClose={() => { setSelected(null); setResume(null); }} onFavorite={() => toggleFavorite(selected)} onProgress={updateProgress} />
      )}
    </div>
  );
}

function TitleBar() {
  return <div className="titlebar"><span>VideoGET</span><div className="window-actions"><button onClick={() => window.lumen.minimize()}><Minus size={14} /></button><button onClick={() => window.lumen.maximize()}><Maximize2 size={13} /></button><button className="close" onClick={() => window.lumen.close()}><X size={15} /></button></div></div>;
}

function Discover({ items, loading, onOpen, favoriteKeys, onFavorite, onSearch, onFavorites, proxyPort }: MediaGridProps & { onSearch: () => void; onFavorites: () => void }) {
  const [source, setSource] = useState('all');
  const [mediaType, setMediaType] = useState<MediaCategory>('all');
  const [sort, setSort] = useState<'recent' | 'year' | 'title'>('recent');
  const sources = useMemo(() => [...new Map(items.map((item) => [item.sourceId, item.sourceName])).entries()], [items]);
  const visibleItems = useMemo(() => {
    const filtered = items.filter((item) => (source === 'all' || item.sourceId === source) && (mediaType === 'all' || item.category === mediaType));
    if (sort === 'title') return [...filtered].sort((a, b) => a.title.localeCompare(b.title, 'zh-CN'));
    if (sort === 'year') return [...filtered].sort((a, b) => Number(b.year ?? 0) - Number(a.year ?? 0));
    return filtered;
  }, [items, mediaType, sort, source]);

  return <div className="page discover-page library-page">
    <header className="library-toolbar">
      <div><span className="eyebrow">本地优先 · 多源聚合</span><h1>媒体库</h1><p>浏览、筛选并直接打开已聚合的影视内容</p></div>
      <button className="search-launcher" onClick={onSearch}><Search size={18} /><span>搜索片名、演员或关键词</span><kbd>Ctrl K</kbd></button>
    </header>
    <div className="library-filters" aria-label="媒体库筛选">
      <label className="filter-control"><LibraryBig size={17} /><span>片库</span><select aria-label="选择片库" value={source} onChange={(event) => setSource(event.target.value)}><option value="all">全部来源</option>{sources.map(([id, name]) => <option key={id} value={id}>{name}</option>)}</select><ChevronDown size={15} /></label>
      <label className="filter-control"><Grid2X2 size={17} /><span>类型</span><select aria-label="选择类型" value={mediaType} onChange={(event) => setMediaType(event.target.value as MediaCategory)}>{categories.map((item) => <option key={item.value} value={item.value}>{item.label}</option>)}</select><ChevronDown size={15} /></label>
      <button className="filter-action" onClick={onFavorites}><Heart size={17} /><span>我的收藏</span>{favoriteKeys.size > 0 && <small>{favoriteKeys.size}</small>}</button>
      <label className="filter-control"><ArrowDownUp size={17} /><span>排序</span><select aria-label="选择排序方式" value={sort} onChange={(event) => setSort(event.target.value as 'recent' | 'year' | 'title')}><option value="recent">聚合顺序</option><option value="year">年份从新到旧</option><option value="title">片名排序</option></select><ChevronDown size={15} /></label>
      <span className="library-count">{loading ? '正在聚合来源...' : `${visibleItems.length} 部作品`}</span>
    </div>
    <MediaGrid items={visibleItems} loading={loading} onOpen={onOpen} favoriteKeys={favoriteKeys} onFavorite={onFavorite} proxyPort={proxyPort} />
  </div>;
}

function SearchView({ query, setQuery, category, setCategory, items, loading, meta, ...gridProps }: MediaGridProps & { query: string; setQuery: (value: string) => void; category: MediaCategory; setCategory: (value: MediaCategory) => void; meta: { elapsedMs: number; failures: number } }) {
  return <div className="page search-page">
    <header className="search-hero"><h1>搜索</h1><div className="search-field"><Search size={20} /><input autoFocus value={query} onChange={(event) => setQuery(event.target.value)} placeholder="片名、演员或关键词" />{loading && <LoaderCircle className="spin" size={19} />}{query && !loading && <button onClick={() => setQuery('')}><X size={17} /></button>}</div></header>
    <div className="segmented-control">{categories.map((item) => <button key={item.value} className={category === item.value ? 'selected' : ''} onClick={() => setCategory(item.value)}>{item.label}</button>)}</div>
    <div className="result-summary"><span>{loading ? '正在聚合来源...' : `${items.length} 个结果`}</span>{!loading && meta.elapsedMs > 0 && <small>{(meta.elapsedMs / 1000).toFixed(1)} 秒{meta.failures ? ` · ${meta.failures} 个来源暂不可用` : ''}</small>}</div>
    <MediaGrid items={items} loading={loading} {...gridProps} />
  </div>;
}

interface ShortPlayback { url: string; originalUrl: string }

function ShortFeedItem({ item, index, settings, favorite, onFavorite, onOpen, onActive }: {
  item: MediaItem; index: number; settings: AppSettings; favorite: boolean;
  onFavorite: (item: MediaItem) => void; onOpen: (item: MediaItem) => void; onActive: (index: number) => void;
}) {
  const rootRef = useRef<HTMLElement>(null);
  const videoRef = useRef<HTMLVideoElement>(null);
  const [active, setActive] = useState(false);
  const [playback, setPlayback] = useState<ShortPlayback | null>(null);
  const [loadingPlayback, setLoadingPlayback] = useState(false);
  const [playbackError, setPlaybackError] = useState('');
  const [playing, setPlaying] = useState(false);
  const [muted, setMuted] = useState(true);
  const [pausedByUser, setPausedByUser] = useState(false);

  useEffect(() => {
    const element = rootRef.current;
    if (!element || !('IntersectionObserver' in window)) {
      setActive(true);
      onActive(index);
      return;
    }
    const root = element.closest('.short-feed');
    const observer = new IntersectionObserver(([entry]) => {
      const nextActive = entry.isIntersecting && entry.intersectionRatio >= 0.68;
      setActive(nextActive);
      if (nextActive) onActive(index);
      if (!nextActive) setPausedByUser(false);
    }, { root, threshold: [0, 0.68, 1] });
    observer.observe(element);
    return () => observer.disconnect();
  }, [index, onActive]);

  useEffect(() => {
    if (active) return;
    const timer = window.setTimeout(() => {
      setPlayback(null);
      setPlaybackError('');
      setPlaying(false);
    }, 500);
    return () => window.clearTimeout(timer);
  }, [active]);

  useEffect(() => {
    if (!active || playback || playbackError) return;
    let cancelled = false;
    setLoadingPlayback(true);
    void (async () => {
      try {
        const detail = await window.lumen.resolve(item) ?? item;
        const episode = detail.playLines?.flatMap((line) => line.episodes).find((entry) => entry.url);
        if (!episode) throw new Error('暂无可播放内容');
        let url = episode.url;
        let headers = episode.headers;
        if (url.startsWith('videoget-rule:') || url.startsWith('videoget-short:')) {
          const resolved = await window.lumen.play(episode.sourceId ?? item.sourceId, url);
          url = resolved.url;
          headers = resolved.headers;
        }
        if (!cancelled) setPlayback({ originalUrl: url, url: streamUrl(settings, url, headers) });
      } catch (error) {
        if (!cancelled) setPlaybackError(error instanceof Error ? error.message : '加载失败');
      } finally {
        if (!cancelled) setLoadingPlayback(false);
      }
    })();
    return () => { cancelled = true; };
  }, [active, item, playback, playbackError, settings]);

  useEffect(() => {
    const video = videoRef.current;
    if (!video || !playback) return;
    let hls: Hls | null = null;
    const onPlay = () => setPlaying(true);
    const onPause = () => setPlaying(false);
    const onError = () => setPlaybackError('当前视频暂时不可播放');
    video.addEventListener('play', onPlay);
    video.addEventListener('pause', onPause);
    video.addEventListener('error', onError);
    if (/m3u8(?:$|\?)/i.test(playback.originalUrl) && Hls.isSupported()) {
      hls = new Hls({ enableWorker: true, lowLatencyMode: false });
      hls.loadSource(playback.url);
      hls.attachMedia(video);
    } else {
      video.src = playback.url;
    }
    return () => {
      video.pause();
      video.removeAttribute('src');
      video.load();
      hls?.destroy();
      video.removeEventListener('play', onPlay);
      video.removeEventListener('pause', onPause);
      video.removeEventListener('error', onError);
    };
  }, [playback]);

  useEffect(() => {
    const video = videoRef.current;
    if (!video || !playback) return;
    if (active && !pausedByUser) void video.play().catch(() => undefined);
    else video.pause();
  }, [active, pausedByUser, playback]);

  const togglePlayback = () => {
    const video = videoRef.current;
    if (!video || !playback) return;
    if (video.paused) {
      setPausedByUser(false);
      void video.play().catch(() => undefined);
    } else {
      setPausedByUser(true);
      video.pause();
    }
  };

  return <article ref={rootRef} className="short-feed-item">
    <img className="short-feed-poster" src={imageUrl(item.backdrop ?? item.poster, settings.proxyPort, 1280, 1920)} alt="" />
    <video ref={videoRef} className={playback && !playbackError ? 'short-feed-video ready' : 'short-feed-video'} muted={muted} loop playsInline preload="metadata" poster={imageUrl(item.poster, settings.proxyPort, 800, 1200)} onClick={togglePlayback} />
    <span className="short-feed-shade" />
    <div className="short-feed-top"><span>推荐</span><small>第 {String(index + 1).padStart(2, '0')} 条</small></div>
    <div className="short-feed-copy"><span className="short-feed-source">{item.sourceName} · {item.category === 'ai-short' ? 'AI 短视频' : '短视频'}</span><h2>{item.title}</h2><p>{item.summary || item.remarks || '向上滑动继续浏览，点击画面暂停或播放。'}</p><div className="short-feed-meta"><span>{item.year || '精选'}</span><span>{item.quality || '自动画质'}</span><span>{item.remarks || '短内容'}</span></div></div>
    <div className="short-feed-actions">
      <button className={favorite ? 'active' : ''} aria-label={favorite ? '取消收藏' : '收藏'} title={favorite ? '取消收藏' : '收藏'} onClick={() => onFavorite(item)}><Heart size={21} fill={favorite ? 'currentColor' : 'none'} /><span>收藏</span></button>
      <button aria-label="查看详情" title="查看详情" onClick={() => onOpen(item)}><Info size={21} /><span>详情</span></button>
      <button aria-label={muted ? '开启声音' : '静音'} title={muted ? '开启声音' : '静音'} onClick={() => setMuted((value) => !value)}>{muted ? <VolumeX size={21} /> : <Volume2 size={21} />}<span>声音</span></button>
    </div>
    <button className={playing ? 'short-feed-toggle playing' : 'short-feed-toggle'} aria-label={playing ? '暂停' : '播放'} onClick={togglePlayback}>{loadingPlayback ? <LoaderCircle className="spin" size={30} /> : playing ? <Pause size={26} fill="currentColor" /> : <Play size={26} fill="currentColor" />}</button>
    {playbackError && <button className="short-feed-error" onClick={() => { setPlayback(null); setPlaybackError(''); }}>{playbackError} · 重试</button>}
  </article>;
}

function ShortsView({ items, failures, loading, loadingMore, hasMore, onLoadMore, onOpen, onConfigure, mode, onMode, favoriteKeys, onFavorite, settings }: {
  items: MediaItem[]; failures: SearchResponse['failures']; loading: boolean; loadingMore: boolean; hasMore: boolean; onLoadMore: () => void; onOpen: (item: MediaItem) => void; onConfigure: () => void; mode: MediaCategory;
  onMode: (mode: MediaCategory) => void; favoriteKeys: Set<string>; onFavorite: (item: MediaItem) => void; settings: AppSettings;
}) {
  const handleActive = useCallback((index: number) => {
    if (index >= items.length - 3) onLoadMore();
  }, [items.length, onLoadMore]);

  useEffect(() => {
    if (!loading && !loadingMore && hasMore && items.length > 0 && items.length <= 3) onLoadMore();
  }, [hasMore, items.length, loading, loadingMore, onLoadMore]);

  return <div className="page shorts-page"><header className="page-header"><div><span className="eyebrow">沉浸浏览</span><h1>短视频</h1></div><div className="segmented-control compact"><button className={mode === 'short' ? 'selected' : ''} onClick={() => onMode('short')}>短视频</button><button className={mode === 'ai-short' ? 'selected' : ''} onClick={() => onMode('ai-short')}>AI 短视频</button></div></header>
    {loading && !items.length ? <LoadingGrid /> : items.length ? <div className="short-feed">{items.map((item, index) => <ShortFeedItem key={`${item.sourceId}:${item.id}`} item={item} index={index} settings={settings} favorite={favoriteKeys.has(`${item.sourceId}:${item.id}`)} onFavorite={onFavorite} onOpen={onOpen} onActive={handleActive} />)}{loadingMore && <div className="short-feed-loading"><LoaderCircle className="spin" size={18} />正在载入</div>}</div> : <EmptyState icon={Sparkles} title={mode === 'short' ? '平台短视频暂不可用' : '还没有 AI 短视频'} text={mode === 'short' ? (failures.length ? failures.slice(0, 2).map((failure) => `${failure.sourceName}：${failure.message}`).join('；') : '配置 TikHub Bearer Token 后加载 TikTok、抖音与 YouTube Shorts 的真实作品。') : 'AI 短视频是独立分类，不会混入平台短视频推荐。'} action={mode === 'short' ? <button className="primary-button" onClick={onConfigure}><Settings size={16} />配置平台接口</button> : undefined} />}
  </div>;
}

function formatTime(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds <= 0) return '00:00';
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const rest = Math.floor(seconds % 60);
  return hours ? `${hours}:${String(minutes).padStart(2, '0')}:${String(rest).padStart(2, '0')}` : `${String(minutes).padStart(2, '0')}:${String(rest).padStart(2, '0')}`;
}

function LibraryView({ mode, items, onOpen, onRemove, onClear, proxyPort }: { mode: 'favorites' | 'history'; items: MediaItem[] | HistoryItem[]; onOpen: (item: MediaItem, historyItem?: HistoryItem) => void; onRemove: (item: MediaItem) => void; onClear: () => void; proxyPort: number }) {
  const isHistory = mode === 'history';
  return <div className="page"><header className="page-header"><div><span className="eyebrow">只保存在本机</span><h1>{isHistory ? '观看记录' : '我的收藏'}</h1><p className="page-description">{isHistory ? '继续上次的线路、剧集和播放位置' : '保存想看的内容，随时继续播放'}</p></div>{items.length > 0 && <button className="secondary-button danger-text" onClick={() => { if (window.confirm(isHistory ? '清空全部观看记录？' : '清空全部收藏？')) onClear(); }}><Trash2 size={15} />全部清空</button>}</header>
    {items.length ? <div className="library-list">{items.map((item) => {
      const historyItem = isHistory ? item as HistoryItem : null;
      const progress = historyItem && historyItem.duration > 0 ? Math.min(100, historyItem.progress / historyItem.duration * 100) : 0;
      return <div className="library-row" key={`${item.sourceId}:${item.id}`}><img src={imageUrl(item.poster, proxyPort, 240, 360)} alt="" /><button className="library-info" onClick={() => onOpen(item, historyItem ?? undefined)}><strong>{item.title}</strong><span>{historyItem ? `${historyItem.episodeName ?? '上次播放'} · ${formatTime(historyItem.progress)} / ${formatTime(historyItem.duration)}` : item.remarks}</span>{historyItem && <small>继续播放</small>}{progress > 0 && <i style={{ width: `${progress}%` }} />}</button><span className="source-pill">{item.sourceName}</span><button className="icon-button" aria-label={isHistory ? '删除观看记录' : '取消收藏'} title={isHistory ? '删除观看记录' : '取消收藏'} onClick={() => onRemove(item)}><Trash2 size={16} /></button></div>;
    })}</div> : <EmptyState icon={isHistory ? Clock3 : Heart} title={isHistory ? '还没有观看记录' : '收藏还是空的'} text={isHistory ? '开始播放后会自动保存剧集和播放位置。' : '点击影片旁的心形按钮即可收藏。'} />}
  </div>;
}

function SettingsView({ settings, onSettings }: { settings: AppSettings; onSettings: (settings: AppSettings) => void }) {
  const [name, setName] = useState('');
  const [api, setApi] = useState('');
  const [testing, setTesting] = useState<string | null>(null);
  const [testResult, setTestResult] = useState<Record<string, string>>({});
  const [importUrl, setImportUrl] = useState('');
  const [importing, setImporting] = useState(false);
  const [danmakuName, setDanmakuName] = useState('');
  const [danmakuApi, setDanmakuApi] = useState('');
  const [tikHubToken, setTikHubToken] = useState('');
  const fileRef = useRef<HTMLInputElement>(null);

  const saveSources = async (sources: CmsSource[]) => onSettings(await window.lumen.saveSources(sources));
  const saveDanmakuProviders = async (providers: DanmakuProvider[]) => onSettings(await window.lumen.saveDanmakuProviders(providers));
  const tikHubConfigured = settings.sources.some((source) => source.provider?.startsWith('tikhub-') && /^Bearer\s+\S+/i.test(source.headers?.Authorization ?? ''));
  const saveTikHub = async () => {
    const token = tikHubToken.trim();
    if (!token) return;
    await saveSources(settings.sources.map((source) => source.provider?.startsWith('tikhub-') ? {
      ...source,
      enabled: true,
      headers: { ...source.headers, Authorization: `Bearer ${token}` },
    } : source));
    setTikHubToken('');
    setTestResult((current) => ({ ...current, tikhub: 'Token 已保存在本机，抖音与 YouTube Shorts 已启用' }));
  };
  const addSource = () => {
    if (!name.trim() || !/^https?:\/\//i.test(api)) return;
    void saveSources([...settings.sources, { id: `cms-${Date.now()}`, name: name.trim(), type: 'cms', api: api.trim(), enabled: true, searchable: true }]);
    setName(''); setApi('');
  };
  const addDanmakuProvider = () => {
    if (!danmakuName.trim() || !/^https?:\/\//i.test(danmakuApi.trim())) return;
    void saveDanmakuProviders([...settings.danmakuProviders, {
      id: `danmaku-${Date.now()}`, name: danmakuName.trim(), type: 'dandanplay', api: danmakuApi.trim(), enabled: true,
    }]);
    setDanmakuName(''); setDanmakuApi('');
  };
  const importFile = async (file?: File) => {
    if (!file) return;
    setImporting(true);
    try {
      const result = await window.lumen.importContent(await file.text(), file.name);
      onSettings(result.settings);
      const failures = result.failures.length ? `，${result.failures.length} 项失败` : '';
      setTestResult((current) => ({ ...current, import: `已导入 ${result.importedSources} 个点播源${failures}` }));
    } catch (error) {
      setTestResult((current) => ({ ...current, import: error instanceof Error ? error.message : '导入失败' }));
    } finally {
      setImporting(false);
    }
  };
  const importRemoteUrl = async () => {
    if (!/^https?:\/\//i.test(importUrl.trim())) return;
    setImporting(true);
    try {
      const result = await window.lumen.importUrl(importUrl.trim());
      onSettings(result.settings);
      const failures = result.failures.length ? `，${result.failures.length} 项失败` : '';
      setTestResult((current) => ({ ...current, import: `已导入 ${result.importedSources} 个点播源${failures}` }));
      setImportUrl('');
    } catch (error) {
      setTestResult((current) => ({ ...current, import: error instanceof Error ? error.message : '导入失败' }));
    } finally {
      setImporting(false);
    }
  };
  const test = async (source: CmsSource) => {
    setTesting(source.id);
    const result = await window.lumen.testSource(source);
    setTestResult((current) => ({ ...current, [source.id]: result.ok ? `${result.message} · ${result.latencyMs} ms` : result.message }));
    setTesting(null);
  };
  return <div className="page settings-page"><header className="page-header"><div><span className="eyebrow">本机配置</span><h1>设置</h1></div></header>
    <section className="settings-section"><div className="settings-heading"><div><h2>短视频平台 API</h2><p>TikHub Token 用于加载 TikTok、抖音与 YouTube Shorts 的真实平台作品。</p></div><span className="source-state"><span className={tikHubConfigured ? 'status-dot' : 'status-dot off'} />{tikHubConfigured ? '已配置' : '未配置'}</span></div>
      {testResult.tikhub && <div className="inline-notice"><Check size={15} />{testResult.tikhub}</div>}
      <div className="import-url"><div className="field-with-icon"><KeyRound size={16} /><input type="password" value={tikHubToken} onChange={(event) => setTikHubToken(event.target.value)} onKeyDown={(event) => { if (event.key === 'Enter') void saveTikHub(); }} placeholder={tikHubConfigured ? '输入新 Token 进行更新' : 'TikHub Bearer Token'} /></div><button className="primary-button" disabled={!tikHubToken.trim()} onClick={() => void saveTikHub()}><Check size={16} />保存并启用</button></div>
    </section>
    <section className="settings-section"><div className="settings-heading"><div><h2>视频来源</h2><p>支持苹果 CMS 与 TVBox 点播配置，短视频会按来源分类自动聚合。</p></div><div className="settings-actions"><button className="secondary-button" disabled={importing} onClick={() => fileRef.current?.click()}><Upload size={16} />{importing ? '导入中' : '导入配置'}</button></div><input ref={fileRef} type="file" accept=".json,.txt,application/json,text/plain" hidden onChange={(event) => { void importFile(event.target.files?.[0]); event.currentTarget.value = ''; }} /></div>
      {testResult.import && <div className="inline-notice"><Check size={15} />{testResult.import}</div>}
      <div className="import-url"><input value={importUrl} onChange={(event) => setImportUrl(event.target.value)} onKeyDown={(event) => { if (event.key === 'Enter') void importRemoteUrl(); }} placeholder="TVBox 点播配置地址" /><button className="secondary-button" disabled={importing || !/^https?:\/\//i.test(importUrl.trim())} onClick={() => void importRemoteUrl()}><Upload size={16} />导入 URL</button></div>
      <div className="add-source"><input value={name} onChange={(event) => setName(event.target.value)} placeholder="来源名称" /><input value={api} onChange={(event) => setApi(event.target.value)} placeholder="https://example.com/api.php/provide/vod/" /><button className="primary-button" onClick={addSource}><Plus size={16} />添加</button></div>
      <div className="source-list"><div className="source-row builtin"><span className="source-logo"><Film size={17} /></span><div><strong>开放影院</strong><small>内置演示 · 可验证高清播放</small></div><span className="source-state"><span className="status-dot" />已启用</span></div>
        {settings.sources.map((source) => <div className="source-row" key={source.id}><button className={source.enabled ? 'toggle on' : 'toggle'} onClick={() => void saveSources(settings.sources.map((entry) => entry.id === source.id ? { ...entry, enabled: !entry.enabled } : entry))}><span /></button><div><strong>{source.name}</strong><small>{source.type === 'cms' ? source.api : source.type === 'short-api' ? `平台接口 · ${source.provider}` : 'Spider 规则'}</small>{testResult[source.id] && <em>{testResult[source.id]}</em>}</div><button className="text-button" onClick={() => void test(source)} disabled={testing === source.id}>{testing === source.id ? '检测中' : '检测'}</button>{!source.id.startsWith('builtin-') && <button className="icon-button danger" onClick={() => void saveSources(settings.sources.filter((entry) => entry.id !== source.id))}><Trash2 size={16} /></button>}</div>)}
      </div>
    </section>
    <section className="settings-section"><div className="settings-heading"><div><h2>播放质量</h2><p>智能适配会根据带宽自动降档，并将其他选项作为最高画质上限。</p></div></div><div className="quality-options">{(['auto', '1080p', '720p', 'highest'] as const).map((quality) => <button key={quality} className={settings.qualityPreference === quality ? 'selected' : ''} onClick={() => void window.lumen.saveQuality(quality).then(onSettings)}><span>{quality === 'highest' ? '不限制' : quality === 'auto' ? '智能适配' : quality.toUpperCase()}</span>{settings.qualityPreference === quality && <Check size={16} />}</button>)}</div><div className="source-list playback-options"><div className="source-row"><button className={settings.adFiltering ? 'toggle on' : 'toggle'} onClick={() => void window.lumen.saveAdFiltering(!settings.adFiltering).then(onSettings)}><span /></button><div><strong>HLS 广告片段过滤</strong><small>识别 CUE、SCTE-35、Interstitial 与广告分片路径</small></div><span className="source-state">{settings.adFiltering ? '已开启' : '已关闭'}</span></div></div></section>
    <section className="settings-section"><div className="settings-heading"><div><h2>弹幕来源</h2><p>播放器会按片名和集数匹配、合并并去重所有启用来源。</p></div></div>
      <div className="add-source"><input value={danmakuName} onChange={(event) => setDanmakuName(event.target.value)} placeholder="来源名称" /><input value={danmakuApi} onChange={(event) => setDanmakuApi(event.target.value)} placeholder="DandanPlay / LogVar 兼容 API 地址" /><button className="primary-button" onClick={addDanmakuProvider}><Plus size={16} />添加</button></div>
      <div className="source-list">{settings.danmakuProviders.map((provider) => <div className={provider.type === 'bilibili' ? 'source-row builtin' : 'source-row'} key={provider.id}><button className={provider.enabled ? 'toggle on' : 'toggle'} onClick={() => void saveDanmakuProviders(settings.danmakuProviders.map((entry) => entry.id === provider.id ? { ...entry, enabled: !entry.enabled } : entry))}><span /></button><div><strong>{provider.name}</strong><small>{provider.type === 'bilibili' ? '内置番剧匹配与弹幕 XML' : provider.api}</small></div>{provider.type !== 'bilibili' && <button className="icon-button danger" aria-label="删除弹幕来源" title="删除弹幕来源" onClick={() => void saveDanmakuProviders(settings.danmakuProviders.filter((entry) => entry.id !== provider.id))}><Trash2 size={16} /></button>}</div>)}</div>
    </section>
    <section className="settings-section about"><div className="settings-heading"><div><h2>关于 VideoGET</h2><p>本地优先的桌面聚合播放器 · 版本 0.1.0</p></div></div><div className="about-grid"><span><MonitorPlay size={18} />Electron 桌面端</span><span><Star size={18} />ArtPlayer + HLS.js</span><span><Check size={18} />数据保存在本机</span></div></section>
  </div>;
}

interface MediaGridProps { items: MediaItem[]; loading: boolean; onOpen: (item: MediaItem) => void; favoriteKeys: Set<string>; onFavorite: (item: MediaItem) => void; proxyPort: number }
function MediaGrid({ items, loading, onOpen, favoriteKeys, onFavorite, proxyPort }: MediaGridProps) {
  if (loading && !items.length) return <LoadingGrid />;
  if (!items.length) return <EmptyState icon={Search} title="没有找到相关内容" text="换个关键词，或在设置中添加更多视频来源。" />;
  return <div className="media-grid">{items.map((item) => { const sourceCount = item.alternatives?.length ?? 1; const favorite = favoriteKeys.has(`${item.sourceId}:${item.id}`); return <article className="media-card" key={`${item.sourceId}:${item.id}`}><button className="poster-button" onClick={() => onOpen(item)}><img src={imageUrl(item.poster, proxyPort, 800, 1200)} alt={item.title} loading="lazy" /><span className="poster-shade" /><span className="play-button"><Play size={20} fill="currentColor" /></span>{item.quality && <span className="quality-badge">{item.quality}</span>}<span className="source-badge">{sourceCount > 1 ? `${sourceCount} 个来源` : item.sourceName}</span></button><div className="media-info"><button onClick={() => onOpen(item)}><strong>{item.title}</strong><span>{[item.year, item.remarks].filter(Boolean).join(' · ')}</span></button><button aria-label={favorite ? `取消收藏 ${item.title}` : `收藏 ${item.title}`} title={favorite ? '取消收藏' : '收藏'} className={favorite ? 'heart-button active' : 'heart-button'} onClick={() => onFavorite(item)}><Heart size={16} fill={favorite ? 'currentColor' : 'none'} /></button></div></article>; })}</div>;
}

function LoadingGrid() { return <div className="media-grid">{Array.from({ length: 10 }, (_, index) => <div className="media-card skeleton" key={index}><div className="skeleton-poster" /><div className="skeleton-line" /><div className="skeleton-line short" /></div>)}</div>; }
function SectionHeader({ title, subtitle }: { title: string; subtitle: string }) { return <div className="section-header"><div><h2>{title}</h2><p>{subtitle}</p></div><ChevronDown size={17} /></div>; }
function EmptyState({ icon: Icon, title, text, action }: { icon: typeof Search; title: string; text: string; action?: React.ReactNode }) { return <div className="empty-state"><span><Icon size={26} /></span><h2>{title}</h2><p>{text}</p>{action}</div>; }

function PlayerSheet({ item, settings, isFavorite, resume, onClose, onFavorite, onProgress }: { item: MediaItem; settings: AppSettings; isFavorite: boolean; resume: HistoryItem | null; onClose: () => void; onFavorite: () => void; onProgress: (item: MediaItem, progress: number, duration: number, lineName: string, episodeName: string) => void }) {
  const lines = item.playLines ?? [];
  const resumePosition = useMemo(() => {
    if (!resume) return { lineIndex: 0, episodeIndex: 0 };
    const matchedLine = Math.max(0, lines.findIndex((line) => line.name === resume.lineName && line.episodes.some((episode) => episode.name === resume.episodeName)));
    const matchedEpisode = Math.max(0, lines[matchedLine]?.episodes.findIndex((episode) => episode.name === resume.episodeName) ?? 0);
    return { lineIndex: matchedLine, episodeIndex: matchedEpisode };
  }, [item.sourceId, item.id, resume?.watchedAt]);
  const [lineIndex, setLineIndex] = useState(resumePosition.lineIndex);
  const [episodeIndex, setEpisodeIndex] = useState(resumePosition.episodeIndex);
  const container = useRef<HTMLDivElement>(null);
  const player = useRef<Artplayer | null>(null);
  const [qualityLabel, setQualityLabel] = useState('检测画质');
  const [danmakuLabel, setDanmakuLabel] = useState('正在匹配弹幕');
  const [danmakuVisible, setDanmakuVisible] = useState(true);
  const [resumedAt, setResumedAt] = useState(0);
  const [playing, setPlaying] = useState(false);
  const [speedLabel, setSpeedLabel] = useState('1x');
  const speedRef = useRef(1);
  const current = lines[lineIndex]?.episodes[episodeIndex];

  useEffect(() => {
    if (!playing || !container.current || !current) return;
    setQualityLabel('检测画质');
    setDanmakuLabel('正在匹配弹幕');
    setDanmakuVisible(true);
    setResumedAt(0);
    let active = true;
    let instance: Artplayer | null = null;
    let lastSaved = 0;
    let resumeApplied = false;
    const saveProgress = () => {
      if (instance && instance.currentTime > 0 && Number.isFinite(instance.currentTime)) {
        onProgress(item, instance.currentTime, instance.duration || 0, lines[lineIndex]?.name ?? '', current.name);
      }
    };
    void (async () => {
      try {
        const resolved = current.url.startsWith('videoget-rule:') || current.url.startsWith('videoget-short:')
          ? await window.lumen.play(current.sourceId ?? item.sourceId, current.url)
          : { url: current.url, headers: current.headers };
        if (!active || !container.current) return;
        const originalUrl = resolved.url;
        const url = streamUrl(settings, originalUrl, resolved.headers);
        instance = new Artplayer({
          container: container.current,
          url,
          volume: 0.8,
          autoplay: true,
          autoSize: false,
          fullscreen: true,
          fullscreenWeb: true,
          pip: true,
          playbackRate: false,
          aspectRatio: true,
          setting: true,
          hotkey: true,
          theme: '#ffffff',
          lang: 'zh-cn',
          plugins: [artplayerPluginDanmuku({
            danmuku: async () => {
              try {
                const response = await window.lumen.danmaku(item.title, current.name);
                if (active) setDanmakuLabel(response.comments.length
                  ? `${response.comments.length} 条弹幕 · ${response.matches.length} 个源`
                  : response.failures.length ? '弹幕源暂不可用' : '本集暂无弹幕');
                return response.comments.map(({ text, time, mode, color }) => ({ text, time, mode, color }));
              } catch {
                if (active) setDanmakuLabel('弹幕加载失败');
                return [];
              }
            },
            speed: 5,
            opacity: 0.78,
            fontSize: 24,
            margin: [10, '25%'],
            antiOverlap: true,
            synchronousPlayback: true,
            heatmap: true,
            emitter: false,
          })],
          type: /m3u8(?:$|\?)/i.test(originalUrl) ? 'm3u8' : undefined,
          customType: {
            m3u8: (video, sourceUrl, art) => {
              attachHls(video, sourceUrl, art, settings.qualityPreference, setQualityLabel);
            },
          },
        });
        const currentSpeed = speedRef.current;
        const speedLabelStr = currentSpeed === 1 ? '1x' : currentSpeed === 1.5 ? '1.5x' : '2x';
        if (instance.setting.find('videoget-speed')) instance.setting.remove('videoget-speed');
        instance.setting.add({
          name: 'videoget-speed',
          html: '倍速',
          tooltip: speedLabelStr,
          selector: [
            { html: '1x', value: 1, default: currentSpeed === 1 },
            { html: '1.5x', value: 1.5, default: currentSpeed === 1.5 },
            { html: '2x', value: 2, default: currentSpeed === 2 },
          ],
          onSelect(item) {
            instance!.playbackRate = Number(item.value);
            speedRef.current = Number(item.value);
            if (item.$parent?.$tooltip) item.$parent.$tooltip.textContent = String(item.html);
            setSpeedLabel(String(item.html));
            return item.html;
          },
        });
        instance.playbackRate = currentSpeed;
        setSpeedLabel(speedLabelStr);
        instance.on('video:timeupdate', () => {
          if (Date.now() - lastSaved > 5000) {
            lastSaved = Date.now();
            saveProgress();
          }
        });
        instance.on('video:pause', saveProgress);
        instance.on('video:ended', () => {
          if (episodeIndex + 1 < (lines[lineIndex]?.episodes.length ?? 0)) setEpisodeIndex((value) => value + 1);
        });
        instance.on('video:loadedmetadata', () => {
          if (!instance) return;
          const isResumeEpisode = resume?.episodeName === current.name && (!resume.lineName || resume.lineName === lines[lineIndex]?.name);
          if (!resumeApplied && isResumeEpisode && resume.progress > 0 && (!resume.duration || resume.progress < resume.duration - 15)) {
            resumeApplied = true;
            instance.currentTime = Math.min(resume.progress, Math.max(0, instance.duration - 5));
            setResumedAt(instance.currentTime);
          }
          if (!/m3u8(?:$|\?)/i.test(originalUrl) && instance.video.videoHeight > 0) setQualityLabel(`${instance.video.videoHeight}P`);
        });
        player.current = instance;
      } catch {
        if (active) setQualityLabel('规则解析失败');
      }
    })();
    return () => { active = false; saveProgress(); instance?.destroy(false); player.current = null; };
  }, [current?.url, current?.sourceId, lineIndex, episodeIndex, settings.proxyPort, settings.proxyBaseUrl, settings.adFiltering, settings.qualityPreference, playing, onProgress]);

  const toggleDanmaku = () => {
    const plugin = player.current?.plugins.artplayerPluginDanmuku as DanmakuPlugin | undefined;
    if (!plugin) return;
    if (danmakuVisible) plugin.hide(); else plugin.show();
    setDanmakuVisible(!danmakuVisible);
  };

  return <div className="player-backdrop" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}><section className="player-sheet detail-sheet">
    {!current ? <><button className="detail-close icon-button" aria-label="关闭详情" title="关闭详情" onClick={onClose}><X size={20} /></button><EmptyState icon={Film} title="暂无可播放线路" text="当前来源没有返回有效播放地址，请尝试其他来源。" /></> : !playing ? <div className="detail-surface" style={{ backgroundImage: `url("${imageUrl(item.backdrop ?? item.poster, settings.proxyPort, 1800, 1000)}")` }}>
      <div className="detail-surface-shade" />
      <header className="detail-topbar"><button className="icon-button" aria-label="关闭详情" title="关闭详情" onClick={onClose}><X size={20} /></button></header>
      <div className="detail-main"><div className="detail-poster-large"><img src={imageUrl(item.poster, settings.proxyPort, 540, 810)} alt={item.title} /></div><div className="detail-copy-large"><span className="detail-kicker">{item.sourceName} · {item.category === 'series' ? '剧集' : item.category === 'movie' ? '电影' : item.category === 'anime' ? '动漫' : '精选内容'}</span><h2>{item.title}</h2><div className="detail-meta">{[item.year, item.area, item.quality, item.remarks].filter(Boolean).map((value) => <span key={value}>{value}</span>)}</div><p>{item.summary || '选择播放线路，开始观看这部作品。'}</p>{(item.actors || item.director) && <div className="detail-credits">{item.actors && <span><strong>主演</strong>{item.actors}</span>}{item.director && <span><strong>导演</strong>{item.director}</span>}</div>}<div className="detail-actions"><button className="primary-button detail-start" onClick={() => setPlaying(true)}><Play size={18} fill="currentColor" />{resume ? '继续播放' : '立即播放'}</button><button className={isFavorite ? 'detail-favorite active' : 'detail-favorite'} aria-label={isFavorite ? '取消收藏' : '收藏'} title={isFavorite ? '取消收藏' : '收藏'} onClick={onFavorite}><Heart size={20} fill={isFavorite ? 'currentColor' : 'none'} /></button></div></div></div>
      <div className="detail-selection"><div className="line-tabs">{lines.map((line, index) => <button key={line.name} className={lineIndex === index ? 'active' : ''} onClick={() => { setLineIndex(index); setEpisodeIndex(0); }}>{line.name}</button>)}</div><div className="episode-grid">{lines[lineIndex]?.episodes.map((episode, index) => <button key={`${episode.name}-${index}`} className={episodeIndex === index ? 'active' : ''} onClick={() => setEpisodeIndex(index)}>{episode.name}</button>)}</div></div>
    </div> : <><header className="player-header"><div><span>{item.sourceName}</span><h2>{item.title} · {current.name}</h2></div><div><small className="player-status">{qualityLabel}</small><small className="player-status">{speedLabel}</small><small className="player-status danmaku-status">{danmakuLabel}</small><button className={danmakuVisible ? 'icon-button active' : 'icon-button'} aria-label={danmakuVisible ? '关闭弹幕' : '开启弹幕'} title={danmakuVisible ? '关闭弹幕' : '开启弹幕'} onClick={toggleDanmaku}>{danmakuVisible ? <Captions size={18} /> : <CaptionsOff size={18} />}</button><button className={isFavorite ? 'icon-button active' : 'icon-button'} aria-label={isFavorite ? '取消收藏' : '收藏'} title={isFavorite ? '取消收藏' : '收藏'} onClick={onFavorite}><Heart size={18} fill={isFavorite ? 'currentColor' : 'none'} /></button><button className="icon-button" aria-label="返回详情" title="返回详情" onClick={() => setPlaying(false)}><X size={20} /></button></div></header><div className={item.category === 'short' || item.category === 'ai-short' ? 'player-stage vertical-mode' : 'player-stage'} ref={container} />{resumedAt > 0 && <div className="resume-notice"><Clock3 size={14} />已从 {formatTime(resumedAt)} 继续播放</div>}<div className="player-controls"><div className="line-tabs">{lines.map((line, index) => <button key={line.name} className={lineIndex === index ? 'active' : ''} onClick={() => { setLineIndex(index); setEpisodeIndex(0); }}>{line.name}</button>)}</div><div className="episode-grid">{lines[lineIndex]?.episodes.map((episode, index) => <button key={`${episode.name}-${index}`} className={episodeIndex === index ? 'active' : ''} onClick={() => setEpisodeIndex(index)}>{episode.name}</button>)}</div></div></>}
  </section></div>;
}

export default App;
