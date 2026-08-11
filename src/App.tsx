import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import Artplayer from 'artplayer';
import artplayerPluginDanmuku, { type Result as DanmakuPlugin } from 'artplayer-plugin-danmuku';
import Hls from 'hls.js';
import {
  Captions, CaptionsOff, Check, ChevronDown, Clock3, Compass, Film, Heart, LoaderCircle,
  Maximize2, Minimize2, Minus, MonitorPlay, Play, Plus, Radio, Search,
  RefreshCw, Settings, Sparkles, Star, Trash2, Tv, Upload, X,
} from 'lucide-react';
import type { AppSettings, CmsSource, DanmakuProvider, HistoryItem, LibraryState, LiveChannel, MediaCategory, MediaItem } from './types';

type View = 'discover' | 'search' | 'shorts' | 'live' | 'favorites' | 'history' | 'settings';

const categories: Array<{ value: MediaCategory; label: string }> = [
  { value: 'all', label: '全部' },
  { value: 'movie', label: '电影' },
  { value: 'series', label: '电视剧' },
  { value: 'anime', label: '动漫' },
  { value: 'short', label: '短剧' },
  { value: 'ai-short', label: 'AI 短剧' },
];

const navItems: Array<{ id: View; label: string; icon: typeof Compass }> = [
  { id: 'discover', label: '发现', icon: Compass },
  { id: 'search', label: '搜索', icon: Search },
  { id: 'shorts', label: '短剧', icon: Sparkles },
  { id: 'live', label: '直播', icon: Radio },
  { id: 'favorites', label: '收藏', icon: Heart },
  { id: 'history', label: '观看记录', icon: Clock3 },
];

const emptySettings: AppSettings = { sources: [], liveChannels: [], danmakuProviders: [], adFiltering: true, qualityPreference: 'highest', proxyPort: 0 };
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
  return levels.reduce((best, level, index) => {
    const distance = Math.abs((level.height || target) - target);
    const bestDistance = Math.abs((levels[best].height || target) - target);
    return distance < bestDistance || (distance === bestDistance && level.bitrate > levels[best].bitrate) ? index : best;
  }, 0);
}

function attachHls(video: HTMLVideoElement, sourceUrl: string, art: Artplayer, preference: QualityPreference, onQuality?: (label: string) => void, lowLatencyMode = false): void {
  if (!Hls.isSupported()) {
    if (video.canPlayType('application/vnd.apple.mpegurl')) video.src = sourceUrl;
    return;
  }
  const hls = new Hls({ enableWorker: true, lowLatencyMode });
  art.hls = hls;
  hls.loadSource(sourceUrl);
  hls.attachMedia(video);
  hls.on(Hls.Events.MANIFEST_PARSED, () => {
    const selectedLevel = preferredLevel(hls.levels, preference);
    hls.currentLevel = selectedLevel;
    const choices = [{ html: '自动', level: -1 }, ...hls.levels.map((level, index) => ({ html: levelLabel(level, index), level: index }))];
    const selectedLabel = selectedLevel < 0 ? '自动' : levelLabel(hls.levels[selectedLevel], selectedLevel);
    if (art.setting.find('videoget-quality')) art.setting.remove('videoget-quality');
    art.setting.add({
      name: 'videoget-quality',
      html: '画质',
      tooltip: selectedLabel,
      selector: choices.map((choice) => ({ ...choice, default: choice.level === selectedLevel })),
      onSelect(item) {
        hls.currentLevel = Number(item.level);
        if (item.$parent?.$tooltip) item.$parent.$tooltip.textContent = String(item.html);
        onQuality?.(String(item.html));
        return item.html;
      },
    });
    onQuality?.(selectedLabel);
  });
  hls.on(Hls.Events.LEVEL_SWITCHED, (_event, data) => {
    const label = levelLabel(hls.levels[data.level], data.level);
    onQuality?.(hls.autoLevelEnabled ? `自动 · ${label}` : label);
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
  const [searchMeta, setSearchMeta] = useState({ elapsedMs: 0, failures: 0 });
  const [settings, setSettings] = useState<AppSettings>(emptySettings);
  const [library, setLibrary] = useState<LibraryState>(emptyLibrary);
  const [selected, setSelected] = useState<MediaItem | null>(null);
  const [resume, setResume] = useState<HistoryItem | null>(null);
  const [selectedLive, setSelectedLive] = useState<LiveChannel | null>(null);
  const searchTimer = useRef<number>();
  const libraryRef = useRef<LibraryState>(emptyLibrary);
  const saveQueue = useRef<Promise<unknown>>(Promise.resolve());

  const searchMedia = useCallback(async (nextQuery: string, nextCategory: MediaCategory) => {
    setLoading(true);
    try {
      const response = await window.lumen.search(nextQuery, nextCategory);
      setItems(response.items);
      setSearchMeta({ elapsedMs: response.elapsedMs, failures: response.failures.length });
    } finally {
      setLoading(false);
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
        {view === 'discover' && <Discover items={items} loading={loading} onOpen={openMedia} favoriteKeys={favoriteKeys} onFavorite={toggleFavorite} onSearch={() => navigate('search')} proxyPort={settings.proxyPort} />}
        {view === 'search' && (
          <SearchView query={query} setQuery={setQuery} category={category} setCategory={setCategory} items={items} loading={loading}
            meta={searchMeta} onOpen={openMedia} favoriteKeys={favoriteKeys} onFavorite={toggleFavorite} proxyPort={settings.proxyPort} />
        )}
        {view === 'shorts' && <ShortsView items={items} loading={loading} onOpen={openMedia} onMode={(mode) => { setCategory(mode); void searchMedia('', mode); }} mode={category} favoriteKeys={favoriteKeys} onFavorite={toggleFavorite} proxyPort={settings.proxyPort} />}
        {view === 'live' && <LiveView settings={settings} onOpenSettings={() => navigate('settings')} onPlay={setSelectedLive} />}
        {view === 'favorites' && <LibraryView mode="favorites" items={library.favorites} onOpen={openMedia} onRemove={toggleFavorite} onClear={() => clearLibrarySection('favorites')} proxyPort={settings.proxyPort} />}
        {view === 'history' && <LibraryView mode="history" items={library.history} onOpen={openMedia} onRemove={removeHistory} onClear={() => clearLibrarySection('history')} proxyPort={settings.proxyPort} />}
        {view === 'settings' && <SettingsView settings={settings} onSettings={setSettings} />}
      </main>

      {selected && (
        <PlayerSheet item={selected} settings={settings} isFavorite={favoriteKeys.has(`${selected.sourceId}:${selected.id}`)}
          resume={resume} onClose={() => { setSelected(null); setResume(null); }} onFavorite={() => toggleFavorite(selected)} onProgress={updateProgress} />
      )}
      {selectedLive && <LivePlayerSheet channel={selectedLive} settings={settings} onClose={() => setSelectedLive(null)} />}
    </div>
  );
}

function TitleBar() {
  return <div className="titlebar"><span>VideoGET</span><div className="window-actions"><button onClick={() => window.lumen.minimize()}><Minus size={14} /></button><button onClick={() => window.lumen.maximize()}><Maximize2 size={13} /></button><button className="close" onClick={() => window.lumen.close()}><X size={15} /></button></div></div>;
}

function Discover({ items, loading, onOpen, favoriteKeys, onFavorite, onSearch, proxyPort }: MediaGridProps & { onSearch: () => void }) {
  const featured = items[0];
  return <div className="page discover-page">
    <header className="page-header"><div><span className="eyebrow">今晚看什么</span><h1>发现好内容</h1></div><button className="search-launcher" onClick={onSearch}><Search size={17} /><span>搜索电影、剧集、动漫、短剧</span><kbd>Ctrl K</kbd></button></header>
    {featured && <section className="featured" style={{ backgroundImage: `linear-gradient(90deg, rgba(8,8,10,.94) 0%, rgba(8,8,10,.6) 48%, rgba(8,8,10,.12) 100%), url("${imageUrl(featured.backdrop ?? featured.poster, proxyPort, 1600, 900)}")` }}>
      <div className="featured-content"><span className="featured-kicker">开放影院精选</span><h2>{featured.title}</h2><p>{featured.summary}</p><div className="featured-meta"><span>{featured.year}</span><span>{featured.quality}</span><span>{featured.remarks}</span></div><button className="primary-button" onClick={() => onOpen(featured)}><Play size={17} fill="currentColor" />立即播放</button></div>
    </section>}
    <SectionHeader title="最近精选" subtitle="开放内容与已配置来源" />
    <MediaGrid items={items} loading={loading} onOpen={onOpen} favoriteKeys={favoriteKeys} onFavorite={onFavorite} proxyPort={proxyPort} />
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

function ShortsView({ items, loading, onOpen, mode, onMode, favoriteKeys, onFavorite, proxyPort }: { items: MediaItem[]; loading: boolean; onOpen: (item: MediaItem) => void; mode: MediaCategory; onMode: (mode: MediaCategory) => void; favoriteKeys: Set<string>; onFavorite: (item: MediaItem) => void; proxyPort: number }) {
  return <div className="page"><header className="page-header"><div><span className="eyebrow">短内容</span><h1>短剧流</h1></div><div className="segmented-control compact"><button className={mode === 'short' ? 'selected' : ''} onClick={() => onMode('short')}>短剧</button><button className={mode === 'ai-short' ? 'selected' : ''} onClick={() => onMode('ai-short')}>AI 短剧</button></div></header>
    {loading ? <LoadingGrid /> : items.length ? <div className="short-grid">{items.map((item) => { const favorite = favoriteKeys.has(`${item.sourceId}:${item.id}`); return <article className="short-card-wrap" key={`${item.sourceId}:${item.id}`}><button className="short-card" onClick={() => onOpen(item)}><img src={imageUrl(item.poster, proxyPort, 800, 1200)} alt="" /><span className="short-overlay"><Play size={22} fill="currentColor" /><strong>{item.title}</strong><small>{item.remarks || item.sourceName}</small></span></button><button className={favorite ? 'short-favorite active' : 'short-favorite'} aria-label={favorite ? '取消收藏' : '收藏'} title={favorite ? '取消收藏' : '收藏'} onClick={() => onFavorite(item)}><Heart size={17} fill={favorite ? 'currentColor' : 'none'} /></button></article>; })}</div> : <EmptyState icon={Sparkles} title="这个频道还没有内容" text="在设置中导入包含短剧分类的视频源。" />}
  </div>;
}

function LiveView({ settings, onOpenSettings, onPlay }: { settings: AppSettings; onOpenSettings: () => void; onPlay: (channel: LiveChannel) => void }) {
  const [liveQuery, setLiveQuery] = useState('');
  const [group, setGroup] = useState('全部');
  const groups = useMemo(() => ['全部', ...new Set(settings.liveChannels.map((channel) => channel.group).filter(Boolean))], [settings.liveChannels]);
  const normalizedQuery = liveQuery.trim().toLowerCase();
  const channels = settings.liveChannels.filter((channel) => {
    const matchesGroup = group === '全部' || channel.group === group;
    const matchesQuery = !normalizedQuery || `${channel.name} ${channel.group} ${channel.sourceName}`.toLowerCase().includes(normalizedQuery);
    return matchesGroup && matchesQuery;
  });
  useEffect(() => { if (!groups.includes(group)) setGroup('全部'); }, [group, groups]);

  return <div className="page live-page"><header className="page-header"><div><span className="eyebrow">实时频道</span><h1>直播</h1></div>{settings.liveChannels.length > 0 && <div className="live-search"><Search size={17} /><input value={liveQuery} onChange={(event) => setLiveQuery(event.target.value)} placeholder="搜索频道" />{liveQuery && <button onClick={() => setLiveQuery('')}><X size={16} /></button>}</div>}</header>
    {settings.liveChannels.length ? <><div className="live-toolbar"><div className="line-tabs live-groups">{groups.map((item) => <button key={item} className={group === item ? 'active' : ''} onClick={() => setGroup(item)}>{item}</button>)}</div><span>{channels.length} 个频道</span></div>{channels.length ? <div className="live-list">{channels.map((channel) => <button className="live-row" key={channel.id} onClick={() => onPlay(channel)}><span className="live-icon">{channel.logo ? <img src={imageUrl(channel.logo, settings.proxyPort, 96, 96)} alt="" /> : <Radio size={18} />}</span><div><strong>{channel.name}</strong><small>{channel.group} · {channel.sourceName}{(channel.urls?.length ?? 1) > 1 ? ` · ${channel.urls?.length} 条线路` : ''}</small></div><span className="icon-button"><Play size={17} fill="currentColor" /></span></button>)}</div> : <EmptyState icon={Search} title="没有匹配的频道" text="调整关键词或频道分组。" />}</> : <EmptyState icon={Tv} title="尚未添加直播源" text="导入 TVBox 配置或 M3U 播放列表后，频道会显示在这里。" action={<button className="secondary-button" onClick={onOpenSettings}>管理来源</button>} />}
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
  const fileRef = useRef<HTMLInputElement>(null);

  const saveSources = async (sources: CmsSource[]) => onSettings(await window.lumen.saveSources(sources));
  const saveDanmakuProviders = async (providers: DanmakuProvider[]) => onSettings(await window.lumen.saveDanmakuProviders(providers));
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
      setTestResult((current) => ({ ...current, import: `已导入 ${result.importedSources} 个点播源、${result.importedLives} 个直播频道${failures}` }));
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
      setTestResult((current) => ({ ...current, import: `已导入 ${result.importedSources} 个点播源、${result.importedLives} 个直播频道${failures}` }));
      setImportUrl('');
    } catch (error) {
      setTestResult((current) => ({ ...current, import: error instanceof Error ? error.message : '导入失败' }));
    } finally {
      setImporting(false);
    }
  };
  const syncIptv = async () => {
    setImporting(true);
    try {
      const result = await window.lumen.importIptvCatalog();
      onSettings(result.settings);
      setTestResult((current) => ({ ...current, import: `IPTV 目录已同步，新增 ${result.importedLives} 个频道` }));
    } catch (error) {
      setTestResult((current) => ({ ...current, import: error instanceof Error ? error.message : 'IPTV 同步失败' }));
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
    <section className="settings-section"><div className="settings-heading"><div><h2>视频来源</h2><p>支持苹果 CMS、TVBox 配置以及 M3U/M3U8 直播列表。</p></div><div className="settings-actions"><button className="secondary-button" disabled={importing} onClick={() => void syncIptv()}><RefreshCw size={16} />同步 IPTV</button><button className="secondary-button" disabled={importing} onClick={() => fileRef.current?.click()}><Upload size={16} />{importing ? '导入中' : '导入文件'}</button></div><input ref={fileRef} type="file" accept=".json,.txt,.m3u,.m3u8,application/json,audio/x-mpegurl" hidden onChange={(event) => { void importFile(event.target.files?.[0]); event.currentTarget.value = ''; }} /></div>
      {testResult.import && <div className="inline-notice"><Check size={15} />{testResult.import}</div>}
      <div className="import-url"><input value={importUrl} onChange={(event) => setImportUrl(event.target.value)} onKeyDown={(event) => { if (event.key === 'Enter') void importRemoteUrl(); }} placeholder="TVBox 或 M3U 远程地址" /><button className="secondary-button" disabled={importing || !/^https?:\/\//i.test(importUrl.trim())} onClick={() => void importRemoteUrl()}><Upload size={16} />导入 URL</button></div>
      <div className="add-source"><input value={name} onChange={(event) => setName(event.target.value)} placeholder="来源名称" /><input value={api} onChange={(event) => setApi(event.target.value)} placeholder="https://example.com/api.php/provide/vod/" /><button className="primary-button" onClick={addSource}><Plus size={16} />添加</button></div>
      <div className="source-list"><div className="source-row builtin"><span className="source-logo"><Film size={17} /></span><div><strong>开放影院</strong><small>内置演示 · 可验证高清播放</small></div><span className="source-state"><span className="status-dot" />已启用</span></div>
        {settings.sources.map((source) => <div className="source-row" key={source.id}><button className={source.enabled ? 'toggle on' : 'toggle'} onClick={() => void saveSources(settings.sources.map((entry) => entry.id === source.id ? { ...entry, enabled: !entry.enabled } : entry))}><span /></button><div><strong>{source.name}</strong><small>{source.type === 'cms' ? source.api : 'Spider 规则'}</small>{testResult[source.id] && <em>{testResult[source.id]}</em>}</div><button className="text-button" onClick={() => void test(source)} disabled={testing === source.id}>{testing === source.id ? '检测中' : '检测'}</button><button className="icon-button danger" onClick={() => void saveSources(settings.sources.filter((entry) => entry.id !== source.id))}><Trash2 size={16} /></button></div>)}
      </div>
    </section>
    <section className="settings-section"><div className="settings-heading"><div><h2>播放质量</h2><p>优先选择源提供的最高分辨率；实际画质由视频源决定。</p></div></div><div className="quality-options">{(['highest', 'auto', '1080p', '720p'] as const).map((quality) => <button key={quality} className={settings.qualityPreference === quality ? 'selected' : ''} onClick={() => void window.lumen.saveQuality(quality).then(onSettings)}><span>{quality === 'highest' ? '最高画质' : quality === 'auto' ? '智能适配' : quality.toUpperCase()}</span>{settings.qualityPreference === quality && <Check size={16} />}</button>)}</div><div className="source-list playback-options"><div className="source-row"><button className={settings.adFiltering ? 'toggle on' : 'toggle'} onClick={() => void window.lumen.saveAdFiltering(!settings.adFiltering).then(onSettings)}><span /></button><div><strong>HLS 广告片段过滤</strong><small>识别 CUE、SCTE-35、Interstitial 与广告分片路径</small></div><span className="source-state">{settings.adFiltering ? '已开启' : '已关闭'}</span></div></div></section>
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
  return <div className="media-grid">{items.map((item) => { const sourceCount = item.alternatives?.length ?? 1; return <article className="media-card" key={`${item.sourceId}:${item.id}`}><button className="poster-button" onClick={() => onOpen(item)}><img src={imageUrl(item.poster, proxyPort, 800, 1200)} alt={item.title} loading="lazy" /><span className="poster-shade" /><span className="play-button"><Play size={20} fill="currentColor" /></span>{item.quality && <span className="quality-badge">{item.quality}</span>}<span className="source-badge">{sourceCount > 1 ? `${sourceCount} 个来源` : item.sourceName}</span></button><div className="media-info"><button onClick={() => onOpen(item)}><strong>{item.title}</strong><span>{[item.year, item.remarks].filter(Boolean).join(' · ')}</span></button><button className={favoriteKeys.has(`${item.sourceId}:${item.id}`) ? 'heart-button active' : 'heart-button'} onClick={() => onFavorite(item)}><Heart size={16} fill={favoriteKeys.has(`${item.sourceId}:${item.id}`) ? 'currentColor' : 'none'} /></button></div></article>; })}</div>;
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
  const current = lines[lineIndex]?.episodes[episodeIndex];

  useEffect(() => {
    if (!container.current || !current) return;
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
        const resolved = current.url.startsWith('videoget-rule:')
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
          playbackRate: true,
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
  }, [current?.url, current?.sourceId, lineIndex, episodeIndex, settings.proxyPort, settings.proxyBaseUrl, settings.adFiltering, settings.qualityPreference, onProgress]);

  const toggleDanmaku = () => {
    const plugin = player.current?.plugins.artplayerPluginDanmuku as DanmakuPlugin | undefined;
    if (!plugin) return;
    if (danmakuVisible) plugin.hide(); else plugin.show();
    setDanmakuVisible(!danmakuVisible);
  };

  return <div className="player-backdrop" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}><section className="player-sheet"><header className="player-header"><div><span>{item.sourceName}</span><h2>{item.title}</h2></div><div><small className="player-status">{qualityLabel}</small><small className="player-status danmaku-status">{danmakuLabel}</small><button className={danmakuVisible ? 'icon-button active' : 'icon-button'} aria-label={danmakuVisible ? '关闭弹幕' : '开启弹幕'} title={danmakuVisible ? '关闭弹幕' : '开启弹幕'} onClick={toggleDanmaku}>{danmakuVisible ? <Captions size={18} /> : <CaptionsOff size={18} />}</button><button className={isFavorite ? 'icon-button active' : 'icon-button'} aria-label={isFavorite ? '取消收藏' : '收藏'} title={isFavorite ? '取消收藏' : '收藏'} onClick={onFavorite}><Heart size={18} fill={isFavorite ? 'currentColor' : 'none'} /></button><button className="icon-button" aria-label="关闭播放器" title="关闭播放器" onClick={onClose}><X size={20} /></button></div></header>
    {current ? <><div className="detail-hero" style={{ backgroundImage: `linear-gradient(90deg, rgba(10,11,14,.96) 0%, rgba(10,11,14,.78) 48%, rgba(10,11,14,.25) 100%), url("${imageUrl(item.backdrop ?? item.poster, settings.proxyPort, 1500, 840)}")` }}><div className="detail-poster"><img src={imageUrl(item.poster, settings.proxyPort, 420, 630)} alt="" /></div><div className="detail-copy"><span className="detail-kicker">{item.sourceName} · {item.category === 'series' ? '剧集' : item.category === 'movie' ? '电影' : '精选内容'}</span><h3>{item.title}</h3><div className="detail-meta">{[item.year, item.area, item.quality, item.remarks].filter(Boolean).map((value) => <span key={value}>{value}</span>)}</div><p>{item.summary || '打开线路，开始播放这部作品。'}</p><button className="primary-button detail-play" onClick={() => player.current?.play()}><Play size={16} fill="currentColor" />继续播放</button></div></div><div className={item.category === 'short' || item.category === 'ai-short' ? 'player-stage vertical-mode' : 'player-stage'} ref={container} />{resumedAt > 0 && <div className="resume-notice"><Clock3 size={14} />已从 {formatTime(resumedAt)} 继续播放</div>}<div className="player-controls"><div className="line-tabs">{lines.map((line, index) => <button key={line.name} className={lineIndex === index ? 'active' : ''} onClick={() => { setLineIndex(index); setEpisodeIndex(0); }}>{line.name}</button>)}</div><div className="episode-grid">{lines[lineIndex]?.episodes.map((episode, index) => <button key={`${episode.name}-${index}`} className={episodeIndex === index ? 'active' : ''} onClick={() => setEpisodeIndex(index)}>{episode.name}</button>)}</div></div></> : <EmptyState icon={Film} title="暂无可播放线路" text="当前来源没有返回有效播放地址，请尝试其他来源。" />}
  </section></div>;
}

function LivePlayerSheet({ channel, settings, onClose }: { channel: LiveChannel; settings: AppSettings; onClose: () => void }) {
  const urls = channel.urls?.length ? channel.urls : [channel.url];
  const [urlIndex, setUrlIndex] = useState(0);
  const [status, setStatus] = useState('正在连接');
  const container = useRef<HTMLDivElement>(null);
  const originalUrl = urls[urlIndex] ?? channel.url;

  useEffect(() => {
    if (!container.current || !originalUrl) return;
    setStatus('正在连接');
    const url = streamUrl(settings, originalUrl);
    const instance = new Artplayer({
      container: container.current,
      url,
      autoplay: true,
      volume: 0.8,
      isLive: true,
      fullscreen: true,
      fullscreenWeb: true,
      pip: true,
      setting: true,
      hotkey: true,
      theme: '#ffffff',
      lang: 'zh-cn',
      type: /m3u8(?:$|\?)/i.test(originalUrl) ? 'm3u8' : undefined,
      customType: {
        m3u8: (video, sourceUrl, art) => {
          attachHls(video, sourceUrl, art, settings.qualityPreference, undefined, true);
        },
      },
    });
    instance.on('video:playing', () => setStatus('正在播放'));
    instance.on('video:waiting', () => setStatus('正在缓冲'));
    instance.on('video:error', () => setStatus('当前线路播放失败'));
    return () => instance.destroy(false);
  }, [originalUrl, settings.proxyPort]);

  return <div className="player-backdrop" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}><section className="player-sheet live-player-sheet"><header className="player-header"><div><span>{channel.group} · {channel.sourceName}</span><h2>{channel.name}</h2></div><div><small className="player-status">{status}</small><button className="icon-button" onClick={onClose}><X size={20} /></button></div></header><div className="player-stage" ref={container} />{urls.length > 1 && <div className="player-controls"><div className="line-tabs">{urls.map((_url, index) => <button key={`${channel.id}-${index}`} className={urlIndex === index ? 'active' : ''} onClick={() => setUrlIndex(index)}>线路 {index + 1}</button>)}</div></div>}</section></div>;
}

export default App;
