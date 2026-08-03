import vm from 'node:vm';
import { fetchRemoteText } from './net-client.js';
import { OPEN_CATALOG } from './open-catalog.js';
import type { CmsSource, LiveChannel, MediaCategory, MediaItem, MediaVariant, PlayLine, SearchResponse } from './types.js';

const requestHeaders = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131 Safari/537.36',
  Accept: 'application/json,text/plain,*/*',
};

function stripHtml(value: unknown): string {
  return String(value ?? '').replace(/<[^>]+>/g, '').replace(/&nbsp;/g, ' ').trim();
}

export function inferMediaCategory(typeName: string): MediaCategory {
  const text = typeName.normalize('NFKC').toLowerCase();
  if (/\bai\b|人工智能|aigc/.test(text) && /短|剧|漫/.test(text)) return 'ai-short';
  if (/短剧|短视频|微剧|爽文|反转爽|女频恋爱|男频|有声剧/.test(text)) return 'short';
  if (/动漫|动画|国漫|日漫|美漫|番剧|卡通/.test(text)) return 'anime';
  if (/电视剧|连续剧|国产剧|港台剧|香港剧|台湾剧|日韩剧|韩剧|日剧|欧美剧|海外剧|泰剧|综艺|纪录片/.test(text)) return 'series';
  return 'movie';
}

function splitNames(value: string): string[] {
  return value ? value.split('$$$') : [];
}

function parsePlayLines(urls: unknown, from: unknown): PlayLine[] {
  const groups = String(urls ?? '').split('$$$').filter(Boolean);
  const names = splitNames(String(from ?? ''));
  const lines = groups.map((group, index) => ({
    name: names[index] || `线路 ${index + 1}`,
    episodes: group.split('#').map((entry, episodeIndex) => {
      const splitAt = entry.indexOf('$');
      if (splitAt < 0) return { name: `第 ${episodeIndex + 1} 集`, url: entry.trim() };
      return { name: entry.slice(0, splitAt).trim() || `第 ${episodeIndex + 1} 集`, url: entry.slice(splitAt + 1).trim() };
    }).filter((episode) => /^https?:\/\//i.test(episode.url)),
  })).filter((line) => line.episodes.length > 0);
  const directLines = lines.filter((line) => line.episodes.some((episode) => /\.(?:m3u8|mp4)(?:$|[?#])/i.test(episode.url)));
  return (directLines.length ? directLines : lines).sort((left, right) => {
    const score = (line: PlayLine) => {
      const direct = line.episodes.filter((episode) => /\.(?:m3u8|mp4)(?:$|[?#])/i.test(episode.url)).length;
      return direct * 10 + (/m3u8|直连|mp4/i.test(line.name) ? 3 : 0);
    };
    return score(right) - score(left);
  });
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
    category: inferMediaCategory(typeName),
    summary: stripHtml(raw.vod_content ?? raw.vod_blurb ?? ''),
    actors: stripHtml(raw.vod_actor ?? ''),
    director: stripHtml(raw.vod_director ?? ''),
    area: stripHtml(raw.vod_area ?? ''),
    playLines: parsePlayLines(raw.vod_play_url, raw.vod_play_from),
  };
}

async function fetchJson(url: string, source: CmsSource, timeoutMs = 8500): Promise<unknown> {
  const text = await fetchRemoteText(url, {
    timeoutMs,
    headers: { ...requestHeaders, ...(source.headers ?? {}) },
  });
  return JSON.parse(text.replace(/^\uFEFF/, ''));
}

function cmsUrl(api: string, params: Record<string, string>): string {
  const url = new URL(api);
  Object.entries(params).forEach(([key, value]) => url.searchParams.set(key, value));
  return url.toString();
}

async function searchCms(source: CmsSource, query: string): Promise<MediaItem[]> {
  if (!source.api) return [];
  const url = cmsUrl(source.api, { ac: 'videolist', wd: query });
  const data = await fetchJson(url, source) as { list?: Array<Record<string, unknown>>; data?: Array<Record<string, unknown>> };
  return (data.list ?? data.data ?? []).map((item) => normalizeVod(item, source));
}

async function detailCms(source: CmsSource, id: string): Promise<MediaItem | null> {
  if (!source.api) return null;
  const url = cmsUrl(source.api, { ac: 'videolist', ids: id });
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
  const text = await fetchRemoteText(request.url, {
    method: request.method ?? 'GET', headers: { ...requestHeaders, ...request.headers }, body: request.body,
  });
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
  const items = mergeMediaVariants([...local, ...remote]
    .filter((item) => category === 'all' || item.category === category));
  return { items, failures, elapsedMs: Date.now() - started };
}

function canonicalTitle(title: string): string {
  return title.normalize('NFKC').toLowerCase()
    .replace(/[（(]\s*(?:19|20)\d{2}\s*[）)]\s*$/, '')
    .replace(/(?:19|20)\d{2}\s*$/, '')
    .replace(/[\s·•:：,，.。!！?？'"“”‘’《》【】\[\]()（）_-]+/g, '');
}

function variantOf(item: MediaItem): MediaVariant {
  return { id: item.id, sourceId: item.sourceId, sourceName: item.sourceName };
}

export function mergeMediaVariants(items: MediaItem[]): MediaItem[] {
  const groups = new Map<string, MediaItem>();
  for (const item of items) {
    const year = item.year?.match(/(?:19|20)\d{2}/)?.[0] ?? '';
    const key = `${canonicalTitle(item.title)}|${year}`;
    const existing = groups.get(key);
    const incomingVariants = item.alternatives?.length ? item.alternatives : [variantOf(item)];
    if (!existing) {
      groups.set(key, { ...item, alternatives: [...incomingVariants] });
      continue;
    }
    const alternatives = [...(existing.alternatives ?? [variantOf(existing)])];
    const known = new Set(alternatives.map((variant) => `${variant.sourceId}:${variant.id}`));
    for (const variant of incomingVariants) {
      const variantKey = `${variant.sourceId}:${variant.id}`;
      if (!known.has(variantKey)) {
        known.add(variantKey);
        alternatives.push(variant);
      }
    }
    groups.set(key, {
      ...existing,
      poster: existing.poster || item.poster,
      summary: existing.summary || item.summary,
      actors: existing.actors || item.actors,
      director: existing.director || item.director,
      remarks: existing.remarks || item.remarks,
      alternatives,
    });
  }
  return [...groups.values()];
}

export async function getDetail(sources: CmsSource[], sourceId: string, id: string): Promise<MediaItem | null> {
  const local = OPEN_CATALOG.find((item) => item.sourceId === sourceId && item.id === id);
  if (local) return local;
  const source = sources.find((entry) => entry.id === sourceId);
  if (!source) return null;
  if (source.type === 'spider') return (await runSpider(source, 'detail', id))[0] ?? null;
  return detailCms(source, id);
}

export async function resolveMedia(sources: CmsSource[], item: MediaItem): Promise<MediaItem | null> {
  const variants = item.alternatives?.length ? item.alternatives : [variantOf(item)];
  const settled = await Promise.allSettled(variants.map((variant) => getDetail(sources, variant.sourceId, variant.id)));
  const details = settled.flatMap((result) => result.status === 'fulfilled' && result.value ? [result.value] : []);
  if (!details.length) return null;
  const playLines = details.flatMap((detail) => (detail.playLines ?? []).map((line) => ({
    ...line,
    name: `${detail.sourceName} · ${line.name}`,
  })));
  const richest = details.reduce((best, detail) => {
    const score = (value: MediaItem) => (value.summary?.length ?? 0) + (value.poster ? 20 : 0) + (value.actors ? 10 : 0);
    return score(detail) > score(best) ? detail : best;
  }, details[0]);
  return {
    ...item,
    poster: richest.poster || item.poster,
    summary: richest.summary || item.summary,
    actors: richest.actors || item.actors,
    director: richest.director || item.director,
    area: richest.area || item.area,
    remarks: richest.remarks || item.remarks,
    alternatives: variants,
    playLines,
  };
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

export interface LivePlaylistReference { id: string; name: string; url: string }

export function importTvBox(input: unknown): { sources: CmsSource[]; lives: LiveChannel[]; livePlaylists: LivePlaylistReference[] } {
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
  const lives: LiveChannel[] = [];
  const livePlaylists: LivePlaylistReference[] = [];
  (config.lives ?? []).forEach((live, index) => {
    const sourceId = String(live.key ?? `tvbox-live-${index}`);
    const sourceName = String(live.name ?? `直播源 ${index + 1}`);
    const url = String(live.url ?? '');
    if (/^https?:\/\//i.test(url)) livePlaylists.push({ id: sourceId, name: sourceName, url });
    const channels = Array.isArray(live.channels) ? live.channels as Array<Record<string, unknown>> : [];
    channels.forEach((channel, channelIndex) => {
      const channelUrl = String(channel.url ?? '');
      if (!/^https?:\/\//i.test(channelUrl)) return;
      const name = String(channel.name ?? `频道 ${channelIndex + 1}`);
      lives.push({
        id: `${sourceId}-${channelIndex}`, sourceId, sourceName, name,
        group: String(channel.group ?? sourceName), url: channelUrl,
        urls: [channelUrl], logo: String(channel.logo ?? '') || undefined,
      });
    });
  });
  return { sources, lives, livePlaylists };
}
