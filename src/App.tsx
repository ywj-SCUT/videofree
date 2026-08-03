import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import Artplayer from 'artplayer';
import Hls from 'hls.js';
import {
  Check, ChevronDown, Clock3, Compass, Film, Heart, Library, LoaderCircle,
  Maximize2, Minimize2, Minus, MonitorPlay, Play, Plus, Radio, Search,
  Settings, Sparkles, Star, Trash2, Tv, Upload, X,
} from 'lucide-react';
import type { AppSettings, CmsSource, LibraryState, MediaCategory, MediaItem } from './types';

type View = 'discover' | 'search' | 'shorts' | 'live' | 'library' | 'settings';

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
  { id: 'library', label: '片库', icon: Library },
];

const emptySettings: AppSettings = { sources: [], liveChannels: [], qualityPreference: 'highest', proxyPort: 0 };
const emptyLibrary: LibraryState = { favorites: [], history: [] };

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
  const [activeTab, setActiveTab] = useState<'favorites' | 'history'>('favorites');
  const searchTimer = useRef<number>();

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

  const openMedia = async (item: MediaItem) => {
    setLoading(true);
    try {
      const detail = item.playLines?.length ? item : await window.lumen.detail(item.sourceId, item.id);
      setSelected(detail ?? item);
    } finally {
      setLoading(false);
    }
  };

  const saveLibrary = async (next: LibraryState) => {
    setLibrary(next);
    await window.lumen.saveLibrary(next);
  };

  const toggleFavorite = (item: MediaItem) => {
    const exists = library.favorites.some((entry) => entry.id === item.id && entry.sourceId === item.sourceId);
    const favorites = exists
      ? library.favorites.filter((entry) => !(entry.id === item.id && entry.sourceId === item.sourceId))
      : [item, ...library.favorites];
    void saveLibrary({ ...library, favorites });
  };

  const updateProgress = (item: MediaItem, progress: number, duration: number, episodeName: string) => {
    const rest = library.history.filter((entry) => !(entry.id === item.id && entry.sourceId === item.sourceId));
    void saveLibrary({ ...library, history: [{ ...item, progress, duration, episodeName, watchedAt: Date.now() }, ...rest].slice(0, 100) });
  };

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
        {view === 'discover' && <Discover items={items} loading={loading} onOpen={openMedia} favoriteKeys={favoriteKeys} onFavorite={toggleFavorite} onSearch={() => navigate('search')} />}
        {view === 'search' && (
          <SearchView query={query} setQuery={setQuery} category={category} setCategory={setCategory} items={items} loading={loading}
            meta={searchMeta} onOpen={openMedia} favoriteKeys={favoriteKeys} onFavorite={toggleFavorite} />
        )}
        {view === 'shorts' && <ShortsView items={items} loading={loading} onOpen={openMedia} onMode={(mode) => { setCategory(mode); void searchMedia('', mode); }} mode={category} />}
        {view === 'live' && <LiveView settings={settings} onOpenSettings={() => navigate('settings')} />}
        {view === 'library' && <LibraryView library={library} activeTab={activeTab} setActiveTab={setActiveTab} onOpen={openMedia} onRemove={toggleFavorite} />}
        {view === 'settings' && <SettingsView settings={settings} onSettings={setSettings} />}
      </main>

      {selected && (
        <PlayerSheet item={selected} settings={settings} isFavorite={favoriteKeys.has(`${selected.sourceId}:${selected.id}`)}
          onClose={() => setSelected(null)} onFavorite={() => toggleFavorite(selected)} onProgress={updateProgress} />
      )}
    </div>
  );
}

function TitleBar() {
  return <div className="titlebar"><span>VideoGET</span><div className="window-actions"><button onClick={() => window.lumen.minimize()}><Minus size={14} /></button><button onClick={() => window.lumen.maximize()}><Maximize2 size={13} /></button><button className="close" onClick={() => window.lumen.close()}><X size={15} /></button></div></div>;
}

function Discover({ items, loading, onOpen, favoriteKeys, onFavorite, onSearch }: MediaGridProps & { onSearch: () => void }) {
  const featured = items[0];
  return <div className="page discover-page">
    <header className="page-header"><div><span className="eyebrow">今晚看什么</span><h1>发现好内容</h1></div><button className="search-launcher" onClick={onSearch}><Search size={17} /><span>搜索电影、剧集、动漫、短剧</span><kbd>Ctrl K</kbd></button></header>
    {featured && <section className="featured" style={{ backgroundImage: `linear-gradient(90deg, rgba(8,8,10,.94) 0%, rgba(8,8,10,.6) 48%, rgba(8,8,10,.12) 100%), url(${featured.poster})` }}>
      <div className="featured-content"><span className="featured-kicker">开放影院精选</span><h2>{featured.title}</h2><p>{featured.summary}</p><div className="featured-meta"><span>{featured.year}</span><span>{featured.quality}</span><span>{featured.remarks}</span></div><button className="primary-button" onClick={() => onOpen(featured)}><Play size={17} fill="currentColor" />立即播放</button></div>
    </section>}
    <SectionHeader title="最近精选" subtitle="开放内容与已配置来源" />
    <MediaGrid items={items} loading={loading} onOpen={onOpen} favoriteKeys={favoriteKeys} onFavorite={onFavorite} />
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

function ShortsView({ items, loading, onOpen, mode, onMode }: { items: MediaItem[]; loading: boolean; onOpen: (item: MediaItem) => void; mode: MediaCategory; onMode: (mode: MediaCategory) => void }) {
  return <div className="page"><header className="page-header"><div><span className="eyebrow">短内容</span><h1>短剧流</h1></div><div className="segmented-control compact"><button className={mode === 'short' ? 'selected' : ''} onClick={() => onMode('short')}>短剧</button><button className={mode === 'ai-short' ? 'selected' : ''} onClick={() => onMode('ai-short')}>AI 短剧</button></div></header>
    {loading ? <LoadingGrid /> : items.length ? <div className="short-grid">{items.map((item) => <button className="short-card" key={`${item.sourceId}:${item.id}`} onClick={() => onOpen(item)}><img src={item.poster} alt="" /><span className="short-overlay"><Play size={22} fill="currentColor" /><strong>{item.title}</strong><small>{item.remarks || item.sourceName}</small></span></button>)}</div> : <EmptyState icon={Sparkles} title="这个频道还没有内容" text="在设置中导入包含短剧分类的视频源。" />}
  </div>;
}

function LiveView({ settings, onOpenSettings }: { settings: AppSettings; onOpenSettings: () => void }) {
  return <div className="page"><header className="page-header"><div><span className="eyebrow">实时频道</span><h1>直播</h1></div></header>
    {settings.liveChannels.length ? <div className="live-list">{settings.liveChannels.map((channel) => <div className="live-row" key={channel.id}><span className="live-icon"><Radio size={18} /></span><div><strong>{channel.name}</strong><small>{channel.group}</small></div><button className="icon-button"><Play size={17} fill="currentColor" /></button></div>)}</div> : <EmptyState icon={Tv} title="尚未添加直播源" text="导入 TVBox 配置或 M3U 播放列表后，频道会显示在这里。" action={<button className="secondary-button" onClick={onOpenSettings}>管理来源</button>} />}
  </div>;
}

function LibraryView({ library, activeTab, setActiveTab, onOpen, onRemove }: { library: LibraryState; activeTab: 'favorites' | 'history'; setActiveTab: (tab: 'favorites' | 'history') => void; onOpen: (item: MediaItem) => void; onRemove: (item: MediaItem) => void }) {
  const visible: Array<MediaItem | LibraryState['history'][number]> = activeTab === 'favorites' ? library.favorites : library.history;
  return <div className="page"><header className="page-header"><div><span className="eyebrow">只保存在本机</span><h1>我的片库</h1></div></header>
    <div className="segmented-control compact"><button className={activeTab === 'favorites' ? 'selected' : ''} onClick={() => setActiveTab('favorites')}><Heart size={15} />收藏</button><button className={activeTab === 'history' ? 'selected' : ''} onClick={() => setActiveTab('history')}><Clock3 size={15} />观看记录</button></div>
    {visible.length ? <div className="library-list">{visible.map((item) => {
      const historyItem = 'watchedAt' in item ? item as LibraryState['history'][number] : null;
      return <div className="library-row" key={`${item.sourceId}:${item.id}`}><img src={item.poster} alt="" /><button className="library-info" onClick={() => onOpen(item)}><strong>{item.title}</strong><span>{historyItem?.episodeName ?? item.remarks}</span>{historyItem && historyItem.duration > 0 && <i style={{ width: `${Math.min(100, historyItem.progress / historyItem.duration * 100)}%` }} />}</button><span className="source-pill">{item.sourceName}</span>{activeTab === 'favorites' && <button className="icon-button" onClick={() => onRemove(item)}><Trash2 size={16} /></button>}</div>;
    })}</div> : <EmptyState icon={activeTab === 'favorites' ? Heart : Clock3} title={activeTab === 'favorites' ? '收藏还是空的' : '还没有观看记录'} text="播放或收藏的影片会安全地保存在本机。" />}
  </div>;
}

function SettingsView({ settings, onSettings }: { settings: AppSettings; onSettings: (settings: AppSettings) => void }) {
  const [name, setName] = useState('');
  const [api, setApi] = useState('');
  const [testing, setTesting] = useState<string | null>(null);
  const [testResult, setTestResult] = useState<Record<string, string>>({});
  const fileRef = useRef<HTMLInputElement>(null);

  const saveSources = async (sources: CmsSource[]) => onSettings(await window.lumen.saveSources(sources));
  const addSource = () => {
    if (!name.trim() || !/^https?:\/\//i.test(api)) return;
    void saveSources([...settings.sources, { id: `cms-${Date.now()}`, name: name.trim(), type: 'cms', api: api.trim(), enabled: true, searchable: true }]);
    setName(''); setApi('');
  };
  const importFile = async (file?: File) => {
    if (!file) return;
    try {
      const config = JSON.parse(await file.text());
      const result = await window.lumen.importTvBox(config);
      onSettings(result.settings);
      setTestResult((current) => ({ ...current, import: `已导入 ${result.importedSources} 个点播源、${result.importedLives} 个直播源` }));
    } catch (error) {
      setTestResult((current) => ({ ...current, import: error instanceof Error ? error.message : '导入失败' }));
    }
  };
  const test = async (source: CmsSource) => {
    setTesting(source.id);
    const result = await window.lumen.testSource(source);
    setTestResult((current) => ({ ...current, [source.id]: result.ok ? `${result.message} · ${result.latencyMs} ms` : result.message }));
    setTesting(null);
  };
  return <div className="page settings-page"><header className="page-header"><div><span className="eyebrow">本机配置</span><h1>设置</h1></div></header>
    <section className="settings-section"><div className="settings-heading"><div><h2>视频来源</h2><p>支持苹果 CMS API 与 TVBox type 1 / 内联 Spider 规则。</p></div><button className="secondary-button" onClick={() => fileRef.current?.click()}><Upload size={16} />导入 TVBox</button><input ref={fileRef} type="file" accept=".json,application/json" hidden onChange={(event) => void importFile(event.target.files?.[0])} /></div>
      {testResult.import && <div className="inline-notice"><Check size={15} />{testResult.import}</div>}
      <div className="add-source"><input value={name} onChange={(event) => setName(event.target.value)} placeholder="来源名称" /><input value={api} onChange={(event) => setApi(event.target.value)} placeholder="https://example.com/api.php/provide/vod/" /><button className="primary-button" onClick={addSource}><Plus size={16} />添加</button></div>
      <div className="source-list"><div className="source-row builtin"><span className="source-logo"><Film size={17} /></span><div><strong>开放影院</strong><small>内置演示 · 可验证高清播放</small></div><span className="source-state"><span className="status-dot" />已启用</span></div>
        {settings.sources.map((source) => <div className="source-row" key={source.id}><button className={source.enabled ? 'toggle on' : 'toggle'} onClick={() => void saveSources(settings.sources.map((entry) => entry.id === source.id ? { ...entry, enabled: !entry.enabled } : entry))}><span /></button><div><strong>{source.name}</strong><small>{source.type === 'cms' ? source.api : 'Spider 规则'}</small>{testResult[source.id] && <em>{testResult[source.id]}</em>}</div><button className="text-button" onClick={() => void test(source)} disabled={testing === source.id}>{testing === source.id ? '检测中' : '检测'}</button><button className="icon-button danger" onClick={() => void saveSources(settings.sources.filter((entry) => entry.id !== source.id))}><Trash2 size={16} /></button></div>)}
      </div>
    </section>
    <section className="settings-section"><div className="settings-heading"><div><h2>播放质量</h2><p>优先选择源提供的最高分辨率；实际画质由视频源决定。</p></div></div><div className="quality-options">{(['highest', 'auto', '1080p', '720p'] as const).map((quality) => <button key={quality} className={settings.qualityPreference === quality ? 'selected' : ''} onClick={() => void window.lumen.saveQuality(quality).then(onSettings)}><span>{quality === 'highest' ? '最高画质' : quality === 'auto' ? '智能适配' : quality.toUpperCase()}</span>{settings.qualityPreference === quality && <Check size={16} />}</button>)}</div></section>
    <section className="settings-section about"><div className="settings-heading"><div><h2>关于 VideoGET</h2><p>本地优先的桌面聚合播放器 · 版本 0.1.0</p></div></div><div className="about-grid"><span><MonitorPlay size={18} />Electron 桌面端</span><span><Star size={18} />ArtPlayer + HLS.js</span><span><Check size={18} />数据保存在本机</span></div></section>
  </div>;
}

interface MediaGridProps { items: MediaItem[]; loading: boolean; onOpen: (item: MediaItem) => void; favoriteKeys: Set<string>; onFavorite: (item: MediaItem) => void }
function MediaGrid({ items, loading, onOpen, favoriteKeys, onFavorite }: MediaGridProps) {
  if (loading && !items.length) return <LoadingGrid />;
  if (!items.length) return <EmptyState icon={Search} title="没有找到相关内容" text="换个关键词，或在设置中添加更多视频来源。" />;
  return <div className="media-grid">{items.map((item) => <article className="media-card" key={`${item.sourceId}:${item.id}`}><button className="poster-button" onClick={() => onOpen(item)}><img src={item.poster} alt={item.title} loading="lazy" /><span className="poster-shade" /><span className="play-button"><Play size={20} fill="currentColor" /></span>{item.quality && <span className="quality-badge">{item.quality}</span>}<span className="source-badge">{item.sourceName}</span></button><div className="media-info"><button onClick={() => onOpen(item)}><strong>{item.title}</strong><span>{[item.year, item.remarks].filter(Boolean).join(' · ')}</span></button><button className={favoriteKeys.has(`${item.sourceId}:${item.id}`) ? 'heart-button active' : 'heart-button'} onClick={() => onFavorite(item)}><Heart size={16} fill={favoriteKeys.has(`${item.sourceId}:${item.id}`) ? 'currentColor' : 'none'} /></button></div></article>)}</div>;
}

function LoadingGrid() { return <div className="media-grid">{Array.from({ length: 10 }, (_, index) => <div className="media-card skeleton" key={index}><div className="skeleton-poster" /><div className="skeleton-line" /><div className="skeleton-line short" /></div>)}</div>; }
function SectionHeader({ title, subtitle }: { title: string; subtitle: string }) { return <div className="section-header"><div><h2>{title}</h2><p>{subtitle}</p></div><ChevronDown size={17} /></div>; }
function EmptyState({ icon: Icon, title, text, action }: { icon: typeof Search; title: string; text: string; action?: React.ReactNode }) { return <div className="empty-state"><span><Icon size={26} /></span><h2>{title}</h2><p>{text}</p>{action}</div>; }

function PlayerSheet({ item, settings, isFavorite, onClose, onFavorite, onProgress }: { item: MediaItem; settings: AppSettings; isFavorite: boolean; onClose: () => void; onFavorite: () => void; onProgress: (item: MediaItem, progress: number, duration: number, episodeName: string) => void }) {
  const lines = item.playLines ?? [];
  const [lineIndex, setLineIndex] = useState(0);
  const [episodeIndex, setEpisodeIndex] = useState(0);
  const container = useRef<HTMLDivElement>(null);
  const player = useRef<Artplayer | null>(null);
  const current = lines[lineIndex]?.episodes[episodeIndex];

  useEffect(() => {
    if (!container.current || !current) return;
    const originalUrl = current.url;
    const useProxy = settings.proxyPort > 0 && /^https?:\/\//i.test(originalUrl);
    const url = useProxy ? `http://127.0.0.1:${settings.proxyPort}/stream?url=${encodeURIComponent(originalUrl)}` : originalUrl;
    const instance = new Artplayer({
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
      type: /m3u8(?:$|\?)/i.test(originalUrl) ? 'm3u8' : undefined,
      customType: {
        m3u8: (video, sourceUrl, art) => {
          if (Hls.isSupported()) {
            const hls = new Hls({ enableWorker: true, startLevel: settings.qualityPreference === 'highest' ? -1 : undefined });
            hls.loadSource(sourceUrl);
            hls.attachMedia(video);
            art.on('destroy', () => hls.destroy());
          } else if (video.canPlayType('application/vnd.apple.mpegurl')) video.src = sourceUrl;
        },
      },
    });
    let lastSaved = 0;
    instance.on('video:timeupdate', () => {
      if (Date.now() - lastSaved > 5000) {
        lastSaved = Date.now();
        onProgress(item, instance.currentTime, instance.duration || 0, current.name);
      }
    });
    instance.on('video:ended', () => {
      if (episodeIndex + 1 < (lines[lineIndex]?.episodes.length ?? 0)) setEpisodeIndex((value) => value + 1);
    });
    player.current = instance;
    return () => { instance.destroy(false); player.current = null; };
  }, [current?.url, lineIndex, episodeIndex, settings.proxyPort, settings.qualityPreference]);

  return <div className="player-backdrop" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}><section className="player-sheet"><header className="player-header"><div><span>{item.sourceName}</span><h2>{item.title}</h2></div><div><button className={isFavorite ? 'icon-button active' : 'icon-button'} onClick={onFavorite}><Heart size={18} fill={isFavorite ? 'currentColor' : 'none'} /></button><button className="icon-button" onClick={onClose}><X size={20} /></button></div></header>
    {current ? <><div className={item.category === 'short' || item.category === 'ai-short' ? 'player-stage vertical-mode' : 'player-stage'} ref={container} /><div className="player-controls"><div className="line-tabs">{lines.map((line, index) => <button key={line.name} className={lineIndex === index ? 'active' : ''} onClick={() => { setLineIndex(index); setEpisodeIndex(0); }}>{line.name}</button>)}</div><div className="episode-grid">{lines[lineIndex]?.episodes.map((episode, index) => <button key={`${episode.name}-${index}`} className={episodeIndex === index ? 'active' : ''} onClick={() => setEpisodeIndex(index)}>{episode.name}</button>)}</div></div></> : <EmptyState icon={Film} title="暂无可播放线路" text="当前来源没有返回有效播放地址，请尝试其他来源。" />}
  </section></div>;
}

export default App;
