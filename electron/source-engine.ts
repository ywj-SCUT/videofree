import vm from 'node:vm';
import { OPEN_CATALOG } from './open-catalog.js';
import type { CmsSource, MediaCategory, MediaItem, PlayLine, SearchResponse } from './types.js';

const requestHeaders = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131 Safari/537.36',
  Accept: 'application/json,text/plain,*/*',
};

function stripHtml(value: unknown): string {
  return String(value ?? '').replace(/<[^>]+>/g, '').replace(/&nbsp;/g, ' ').trim();
}

function inferCategory(typeName: string): MediaCategory {
  const text = typeName.toLowerCase();
  if (text.includes('ai') && (text.includes('短') || text.includes('剧'))) return 'ai-short';
  if (text.includes('短')) return 'short';
  if (text.includes('动漫') || text.includes('动画') || text.includes('番')) return 'anime';
  if (text.includes('电视剧') || text.includes('连续') || text.includes('综艺')) return 'series';
  return 'movie';
}

function splitNames(value: string): string[] {
  return value ? value.split('$$$') : [];
}

function parsePlayLines(urls: unknown, from: unknown): PlayLine[] {
  const groups = String(urls ?? '').split('$$$').filter(Boolean);
  const names = splitNames(String(from ?? ''));
  return groups.map((group, index) => ({
    name: names[index] || `线路 ${index + 1}`,
    episodes: group.split('#').map((entry, episodeIndex) => {
      const splitAt = entry.indexOf('$');
      if (splitAt < 0) return { name: `第 ${episodeIndex + 1} 集`, url: entry.trim() };
      return { name: entry.slice(0, splitAt).trim() || `第 ${episodeIndex + 1} 集`, url: entry.slice(splitAt + 1).trim() };
    }).filter((episode) => /^https?:\/\//i.test(episode.url)),
  })).filter((line) => line.episodes.length > 0);
}

function normalizeVod(raw: Record<string, unknown>, source: CmsSource): MediaItem {
  const typeName = String(raw.type_name ?? raw.vod_class ?? '');
  return {
    id: String(raw.vod_id ?? raw.id ?? `${source.id}-${raw.vod_name}`),
    sourceId: source.id,
    sourceName: source.name,
    title: stripHtml(raw.vod_name ?? raw.name),
    poster: String(raw.vod_pic ?? raw.pic ?? ''),
    year: String(raw.vod_year ?? ''),
    remarks: stripHtml(raw.vod_remarks ?? raw.note ?? ''),
    category: inferCategory(typeName),
    summary: stripHtml(raw.vod_content ?? raw.vod_blurb ?? ''),
    actors: stripHtml(raw.vod_actor ?? ''),
    director: stripHtml(raw.vod_director ?? ''),
    area: stripHtml(raw.vod_area ?? ''),
    playLines: parsePlayLines(raw.vod_play_url, raw.vod_play_from),
  };
}

async function fetchJson(url: string, source: CmsSource, timeoutMs = 8500): Promise<unknown> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, {
      signal: controller.signal,
      headers: { ...requestHeaders, ...(source.headers ?? {}) },
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const text = await response.text();
    return JSON.parse(text.replace(/^\uFEFF/, ''));
  } finally {
    clearTimeout(timeout);
  }
}

async function searchCms(source: CmsSource, query: string): Promise<MediaItem[]> {
  if (!source.api) return [];
  const separator = source.api.includes('?') ? '&' : '?';
  const url = `${source.api}${separator}ac=videolist&wd=${encodeURIComponent(query)}`;
  const data = await fetchJson(url, source) as { list?: Array<Record<string, unknown>>; data?: Array<Record<string, unknown>> };
  return (data.list ?? data.data ?? []).map((item) => normalizeVod(item, source));
}

async function detailCms(source: CmsSource, id: string): Promise<MediaItem | null> {
  if (!source.api) return null;
  const separator = source.api.includes('?') ? '&' : '?';
  const url = `${source.api}${separator}ac=videolist&ids=${encodeURIComponent(id)}`;
  const data = await fetchJson(url, source) as { list?: Array<Record<string, unknown>>; data?: Array<Record<string, unknown>> };
  const item = (data.list ?? data.data ?? [])[0];
  return item ? normalizeVod(item, source) : null;
}

function validateSpiderScript(script: string): void {
  const blocked = /(?:process|require|import\s*\(|child_process|fs\.|Function\s*\(|eval\s*\()/;
  if (blocked.test(script)) throw new Error('规则包含被禁用的运行时能力');
  if (script.length > 100_000) throw new Error('规则脚本超过 100 KB');
}

async function runSpider(source: CmsSource, operation: 'search' | 'detail', value: string): Promise<MediaItem[]> {
  if (!source.script) return [];
  validateSpiderScript(source.script);
  const sandbox = {
    module: { exports: {} as Record<string, unknown> },
    exports: {},
    console: { log: () => undefined },
    encodeURIComponent,
    JSON,
  };
  vm.createContext(sandbox, { codeGeneration: { strings: false, wasm: false } });
  new vm.Script(source.script, { filename: `${source.id}.spider.js` }).runInContext(sandbox, { timeout: 500 });
  const exported = sandbox.module.exports as Record<string, unknown>;
  const handler = exported[operation];
  if (typeof handler !== 'function') return [];
  const request = await (handler as (value: string) => unknown)(value) as { url: string; method?: string; headers?: Record<string, string>; body?: string; parse?: string };
  const response = await fetch(request.url, {
    method: request.method ?? 'GET', headers: { ...requestHeaders, ...request.headers }, body: request.body,
  });
  const text = await response.text();
  const parser = exported[request.parse ?? `parse${operation[0].toUpperCase()}${operation.slice(1)}`];
  if (typeof parser !== 'function') throw new Error('规则缺少解析函数');
  const parsed = await (parser as (text: string) => unknown)(text);
  return (Array.isArray(parsed) ? parsed : [parsed]).filter(Boolean).map((item) => ({
    ...(item as MediaItem), sourceId: source.id, sourceName: source.name,
  }));
}

export async function aggregateSearch(sources: CmsSource[], query: string, category: MediaCategory): Promise<SearchResponse> {
  const started = Date.now();
  const normalizedQuery = query.trim().toLowerCase();
  const local = OPEN_CATALOG.filter((item) => {
    const matchesQuery = !normalizedQuery || `${item.title} ${item.summary ?? ''}`.toLowerCase().includes(normalizedQuery);
    return matchesQuery && (category === 'all' || item.category === category);
  });
  const active = sources.filter((source) => source.enabled && source.searchable);
  const settled = await Promise.allSettled(active.map((source) => source.type === 'cms'
    ? searchCms(source, query)
    : runSpider(source, 'search', query)));
  const failures: SearchResponse['failures'] = [];
  const remote: MediaItem[] = [];
  settled.forEach((result, index) => {
    if (result.status === 'fulfilled') remote.push(...result.value);
    else failures.push({ sourceId: active[index].id, sourceName: active[index].name, message: result.reason instanceof Error ? result.reason.message : String(result.reason) });
  });
  const seen = new Set<string>();
  const items = [...local, ...remote]
    .filter((item) => category === 'all' || item.category === category)
    .filter((item) => {
      const key = `${item.sourceId}:${item.id}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
  return { items, failures, elapsedMs: Date.now() - started };
}

export async function getDetail(sources: CmsSource[], sourceId: string, id: string): Promise<MediaItem | null> {
  const local = OPEN_CATALOG.find((item) => item.sourceId === sourceId && item.id === id);
  if (local) return local;
  const source = sources.find((entry) => entry.id === sourceId);
  if (!source) return null;
  if (source.type === 'spider') return (await runSpider(source, 'detail', id))[0] ?? null;
  return detailCms(source, id);
}

export async function testSource(source: CmsSource): Promise<{ ok: boolean; latencyMs: number; message: string }> {
  const started = Date.now();
  try {
    if (source.type === 'cms') await searchCms(source, '测试');
    else await runSpider(source, 'search', '测试');
    return { ok: true, latencyMs: Date.now() - started, message: '连接正常' };
  } catch (error) {
    return { ok: false, latencyMs: Date.now() - started, message: error instanceof Error ? error.message : String(error) };
  }
}

export function importTvBox(input: unknown): { sources: CmsSource[]; lives: Array<{ id: string; name: string; group: string; url: string; logo?: string }> } {
  const config = input as { sites?: Array<Record<string, unknown>>; lives?: Array<Record<string, unknown>> };
  const sources = (config.sites ?? []).flatMap((site, index): CmsSource[] => {
    const type = Number(site.type ?? 1);
    const api = String(site.api ?? '');
    const ext = site.ext as Record<string, unknown> | string | undefined;
    if (type === 1 && /^https?:\/\//i.test(api)) {
      return [{ id: String(site.key ?? `tvbox-${index}`), name: String(site.name ?? `视频源 ${index + 1}`), type: 'cms', api, enabled: true, searchable: Number(site.searchable ?? 1) !== 0 }];
    }
    const script = typeof ext === 'object' && typeof ext.script === 'string' ? ext.script : undefined;
    if (type === 3 && script) {
      return [{ id: String(site.key ?? `spider-${index}`), name: String(site.name ?? `规则源 ${index + 1}`), type: 'spider', script, enabled: true, searchable: Number(site.searchable ?? 1) !== 0 }];
    }
    return [];
  });
  const lives = (config.lives ?? []).flatMap((live, index) => {
    const url = String(live.url ?? '');
    return /^https?:\/\//i.test(url) ? [{ id: `live-${index}`, name: String(live.name ?? `直播源 ${index + 1}`), group: '导入', url }] : [];
  });
  return { sources, lives };
}
