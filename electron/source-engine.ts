import { fetchRemoteText } from './net-client.js';
import { OPEN_CATALOG } from './open-catalog.js';
import { episodeForLine, rankRouteCandidates, type RouteCandidate } from './route-engine.js';
import { detailRule, resolveRulePlayback, searchRule, testRule } from './rule-engine.js';
import { resolveShortPlayback, searchShortSource, testShortSource } from './short-video-engine.js';
import type { CmsSource, MediaCategory, MediaItem, MediaVariant, PlaybackResolution, PlayLine, SearchResponse } from './types.js';

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

interface SourceSearchPage {
  items: MediaItem[];
  hasMore: boolean;
}

async function searchCms(source: CmsSource, query: string, page: number): Promise<SourceSearchPage> {
  if (!source.api) return { items: [], hasMore: false };
  const url = cmsUrl(source.api, { ac: 'videolist', wd: query, pg: String(page) });
  const data = await fetchJson(url, source, 4_000) as {
    list?: Array<Record<string, unknown>>;
    data?: Array<Record<string, unknown>>;
    page?: number | string;
    pagecount?: number | string;
  };
  const items = (data.list ?? data.data ?? []).map((item) => normalizeVod(item, source));
  const currentPage = Number(data.page ?? page);
  const pageCount = Number(data.pagecount ?? 0);
  return {
    items,
    hasMore: Number.isFinite(pageCount) && pageCount > 0 ? currentPage < pageCount : items.length > 0,
  };
}

async function detailCms(source: CmsSource, id: string): Promise<MediaItem | null> {
  if (!source.api) return null;
  const url = cmsUrl(source.api, { ac: 'videolist', ids: id });
  const data = await fetchJson(url, source) as { list?: Array<Record<string, unknown>>; data?: Array<Record<string, unknown>> };
  const item = (data.list ?? data.data ?? [])[0];
  return item ? normalizeVod(item, source) : null;
}

export async function aggregateSearch(sources: CmsSource[], query: string, category: MediaCategory, page = 1): Promise<SearchResponse> {
  const started = Date.now();
  const currentPage = Math.max(1, Math.floor(Number(page)) || 1);
  const normalizedQuery = query.trim().toLowerCase();
  const local = currentPage === 1 && category !== 'short' ? OPEN_CATALOG.filter((item) => {
    const matchesQuery = !normalizedQuery || `${item.title} ${item.summary ?? ''}`.toLowerCase().includes(normalizedQuery);
    return matchesQuery && (category === 'all' || item.category === category);
  }) : [];
  const active = sources.filter((source) => {
    if (!source.enabled || !source.searchable) return false;
    if (category === 'short') return source.type === 'short-api';
    return source.type !== 'short-api';
  });
  const settled = await Promise.allSettled(active.map(async (source): Promise<SourceSearchPage> => {
    if (source.type === 'cms') return searchCms(source, query, currentPage);
    if (source.type === 'short-api') return searchShortSource(source, query, currentPage);
    const items = await searchRule(source, query, currentPage);
    return { items, hasMore: items.length > 0 };
  }));
  const failures: SearchResponse['failures'] = [];
  const remote: MediaItem[] = [];
  let hasMore = false;
  settled.forEach((result, index) => {
    if (result.status === 'fulfilled') {
      remote.push(...result.value.items);
      hasMore ||= result.value.hasMore;
    }
    else failures.push({ sourceId: active[index].id, sourceName: active[index].name, message: result.reason instanceof Error ? result.reason.message : String(result.reason) });
  });
  const items = mergeMediaVariants([...local, ...remote]
    .filter((item) => category === 'all' || item.category === category));
  return { items, failures, elapsedMs: Date.now() - started, page: currentPage, hasMore };
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
  if (source.type === 'short-api') return null;
  if (source.type === 'spider') return detailRule(source, id);
  return detailCms(source, id);
}

export async function resolvePlayback(sources: CmsSource[], sourceId: string, token: string): Promise<PlaybackResolution> {
  if (/^https?:\/\//i.test(token)) return { url: token };
  const shortSource = sources.find((entry) => entry.id === sourceId && entry.type === 'short-api');
  if (shortSource && token.startsWith('videoget-short:')) return resolveShortPlayback(shortSource, token);
  const source = sources.find((entry) => entry.id === sourceId && entry.type === 'spider');
  if (!source) throw new Error('没有找到剧集对应的规则源');
  return resolveRulePlayback(source, token);
}

async function waitWithinBudget(task: Promise<unknown>, budgetMs: number): Promise<void> {
  await new Promise<void>((resolve) => {
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      resolve();
    };
    const timeout = setTimeout(finish, budgetMs);
    void task.then(finish, finish);
  });
}

export async function resolveMedia(sources: CmsSource[], item: MediaItem): Promise<MediaItem | null> {
  const variants = item.alternatives?.length ? item.alternatives : [variantOf(item)];
  const details: MediaItem[] = [];
  const pending = variants.map(async (variant) => {
    try {
      const detail = await getDetail(sources, variant.sourceId, variant.id);
      if (detail) details.push(detail);
    } catch {
      // A single unhealthy source must not block details from healthy sources.
    }
  });
  await waitWithinBudget(Promise.all(pending), 5_000);
  if (!details.length) return null;
  const playLines = details.flatMap((detail) => (detail.playLines ?? []).map((line) => ({
    ...line,
    name: `${detail.sourceName} · ${line.name}`,
    episodes: line.episodes.map((episode) => ({
      ...episode,
      sourceId: episode.sourceId ?? detail.sourceId,
    })),
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

function playbackWithTimeout(sources: CmsSource[], sourceId: string, token: string, timeoutMs: number): Promise<PlaybackResolution> {
  return new Promise<PlaybackResolution>((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('线路解析超时')), timeoutMs);
    void resolvePlayback(sources, sourceId, token).then(
      (value) => { clearTimeout(timeout); resolve(value); },
      (error) => { clearTimeout(timeout); reject(error); },
    );
  });
}

export async function routePlayLines(
  sources: CmsSource[],
  lines: PlayLine[],
  episodeName: string,
  episodeIndex: number,
  proxyPort: number,
  adFiltering: boolean,
): Promise<PlayLine[]> {
  if (lines.length < 2) return lines;
  const candidates = (await Promise.all(lines.map(async (line, index): Promise<RouteCandidate | null> => {
    const episode = episodeForLine(line, episodeName, episodeIndex);
    if (!episode) return null;
    try {
      const resolved = /^https?:\/\//i.test(episode.url)
        ? { url: episode.url, headers: episode.headers }
        : await playbackWithTimeout(sources, episode.sourceId ?? '', episode.url, 1_500);
      return { index, name: line.name, url: resolved.url, headers: resolved.headers };
    } catch {
      return null;
    }
  }))).filter((candidate): candidate is RouteCandidate => Boolean(candidate));
  if (candidates.length < 2) return lines;
  const rankedIndexes = await rankRouteCandidates(candidates, { proxyPort, adFiltering, budgetMs: 3_500 });
  const ranked = rankedIndexes.map((index) => lines[index]).filter(Boolean);
  const rankedSet = new Set(rankedIndexes);
  return [...ranked, ...lines.filter((_line, index) => !rankedSet.has(index))];
}

export async function testSource(source: CmsSource): Promise<{ ok: boolean; latencyMs: number; message: string }> {
  const started = Date.now();
  try {
    if (source.type === 'cms') await searchCms(source, '测试', 1);
    else if (source.type === 'short-api') await testShortSource(source);
    else await testRule(source);
    return { ok: true, latencyMs: Date.now() - started, message: '连接正常' };
  } catch (error) {
    return { ok: false, latencyMs: Date.now() - started, message: error instanceof Error ? error.message : String(error) };
  }
}

export function importTvBox(input: unknown): { sources: CmsSource[] } {
  const config = input as { sites?: Array<Record<string, unknown>> };
  const sources = (config.sites ?? []).flatMap((site, index): CmsSource[] => {
    const type = Number(site.type ?? 1);
    const api = String(site.api ?? '');
    const ext = site.ext as Record<string, unknown> | string | undefined;
    if (type === 1 && /^https?:\/\//i.test(api)) {
      return [{ id: String(site.key ?? `tvbox-${index}`), name: String(site.name ?? `视频源 ${index + 1}`), type: 'cms', api, enabled: true, searchable: Number(site.searchable ?? 1) !== 0 }];
    }
    const script = typeof ext === 'object' && typeof ext.script === 'string'
      ? ext.script
      : typeof ext === 'string' && /(?:module\.exports|exports\.)/.test(ext) ? ext : undefined;
    const scriptUrl = typeof ext === 'object' && typeof ext.scriptUrl === 'string'
      ? ext.scriptUrl
      : typeof ext === 'object' && typeof ext.url === 'string' ? ext.url
        : typeof ext === 'string' && /^https?:\/\//i.test(ext) ? ext
          : type === 3 && /^https?:\/\/.*\.js(?:$|\?)/i.test(api) ? api : undefined;
    const ruleConfig = typeof ext === 'object' && ext.config && typeof ext.config === 'object'
      ? ext.config as Record<string, unknown> : undefined;
    if (type === 3 && (script || scriptUrl)) {
      return [{
        id: String(site.key ?? `spider-${index}`), name: String(site.name ?? `规则源 ${index + 1}`),
        type: 'spider', script, scriptUrl, ruleConfig, enabled: true,
        searchable: Number(site.searchable ?? 1) !== 0,
      }];
    }
    return [];
  });
  return { sources };
}
