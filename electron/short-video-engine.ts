import { fetchRemoteText } from './net-client.js';
import type { CmsSource, MediaItem, PlaybackResolution } from './types.js';

interface ShortSourcePage {
  items: MediaItem[];
  hasMore: boolean;
}

type JsonRecord = Record<string, unknown>;

const youtubePageTokens = new Map<string, string[]>();
const tikWmCache = new Map<string, { value: ShortSourcePage; storedAt: number }>();
const tikWmPending = new Map<string, Promise<ShortSourcePage>>();
const TIKWM_CACHE_MS = 30_000;
const TIKWM_STALE_MS = 5 * 60_000;
const TIKWM_MIN_INTERVAL_MS = 1_200;
let lastTikWmRequestAt = 0;

function record(value: unknown): JsonRecord {
  return value && typeof value === 'object' && !Array.isArray(value) ? value as JsonRecord : {};
}

function text(value: unknown): string {
  return typeof value === 'string' || typeof value === 'number' ? String(value).trim() : '';
}

function nested(value: unknown, path: string): unknown {
  return path.split('.').reduce<unknown>((current, key) => record(current)[key], value);
}

function firstUrl(...values: unknown[]): string {
  for (const value of values) {
    if (typeof value === 'string' && /^https?:\/\//i.test(value)) return value;
    if (Array.isArray(value)) {
      const found = firstUrl(...value);
      if (found) return found;
    }
    if (value && typeof value === 'object') {
      const item = record(value);
      const found = firstUrl(item.url_list, item.urlList, item.url, item.play_url, item.playUrl);
      if (found) return found;
    }
  }
  return '';
}

function findArray(value: unknown, keys: string[], depth = 0): unknown[] {
  if (depth > 7 || !value || typeof value !== 'object') return [];
  const item = record(value);
  for (const key of keys) {
    if (Array.isArray(item[key])) return item[key] as unknown[];
  }
  for (const child of Object.values(item)) {
    const found = findArray(child, keys, depth + 1);
    if (found.length) return found;
  }
  return [];
}

function findText(value: unknown, keys: string[], depth = 0): string {
  if (depth > 7 || !value || typeof value !== 'object') return '';
  const item = record(value);
  for (const key of keys) {
    const found = text(item[key]);
    if (found) return found;
  }
  for (const child of Object.values(item)) {
    const found = findText(child, keys, depth + 1);
    if (found) return found;
  }
  return '';
}

function compactCount(value: unknown): string {
  const count = Number(value);
  if (!Number.isFinite(count) || count <= 0) return '';
  if (count >= 100_000_000) return `${(count / 100_000_000).toFixed(1)} 亿播放`;
  if (count >= 10_000) return `${(count / 10_000).toFixed(1)} 万播放`;
  return `${Math.floor(count)} 播放`;
}

function directLine(source: CmsSource, url: string, headers?: Record<string, string>): MediaItem['playLines'] {
  return [{ name: source.name, episodes: [{ name: '短视频', url, sourceId: source.id, headers }] }];
}

function encodeShortToken(provider: string, videoId: string): string {
  return `videoget-short:${Buffer.from(JSON.stringify({ provider, videoId }), 'utf8').toString('base64url')}`;
}

function decodeShortToken(token: string): { provider: string; videoId: string } {
  try {
    const value = JSON.parse(Buffer.from(token.slice('videoget-short:'.length), 'base64url').toString('utf8')) as JsonRecord;
    const provider = text(value.provider);
    const videoId = text(value.videoId);
    if (!provider || !videoId) throw new Error();
    return { provider, videoId };
  } catch {
    throw new Error('短视频播放令牌无效');
  }
}

export function normalizeTikWmItems(payload: unknown, source: CmsSource): MediaItem[] {
  const values = Array.isArray(record(payload).data) ? record(payload).data as unknown[] : [];
  return values.flatMap((value): MediaItem[] => {
    const item = record(value);
    const id = text(item.video_id ?? item.id);
    const url = firstUrl(item.play, item.wmplay);
    if (!id || !url) return [];
    const author = record(item.author);
    const authorName = text(author.nickname ?? author.unique_id);
    const duration = Number(item.duration);
    const metrics = [Number.isFinite(duration) && duration > 0 ? `${Math.round(duration)} 秒` : '', compactCount(item.play_count)].filter(Boolean);
    return [{
      id: `tikwm-${id}`,
      sourceId: source.id,
      sourceName: authorName ? `TikTok · ${authorName}` : 'TikTok',
      title: text(item.title ?? item.content_desc) || `TikTok ${id}`,
      poster: firstUrl(item.cover, item.origin_cover, item.ai_dynamic_cover),
      category: 'short',
      summary: text(item.content_desc ?? item.title),
      remarks: metrics.join(' · '),
      playLines: directLine(source, url, { Referer: 'https://www.tiktok.com/' }),
      quality: '自适应',
    }];
  });
}

export function normalizeTikHubItems(payload: unknown, source: CmsSource): MediaItem[] {
  const provider = source.provider ?? '';
  const platform = provider === 'tikhub-douyin' ? '抖音' : provider === 'tikhub-youtube' ? 'YouTube Shorts' : 'TikTok';
  const values = findArray(payload, provider === 'tikhub-youtube'
    ? ['shorts', 'items', 'videos']
    : ['aweme_list', 'awemeList', 'item_list', 'itemList', 'items']);
  return values.flatMap((value): MediaItem[] => {
    const item = record(value);
    const id = text(item.aweme_id ?? item.awemeId ?? item.video_id ?? item.videoId ?? item.id);
    if (!id) return [];
    const author = record(item.author);
    const authorName = text(author.nickname ?? author.unique_id ?? author.uniqueId ?? item.channel_name ?? item.author_name);
    const poster = firstUrl(
      item.cover, item.thumbnail, item.thumbnail_url, item.thumbnails,
      nested(item, 'video.cover'), nested(item, 'video.origin_cover'), nested(item, 'video.originCover'),
    );
    const playUrl = firstUrl(
      item.play, item.play_url, item.download_url,
      nested(item, 'video.play_addr'), nested(item, 'video.playAddr'),
      nested(item, 'video.download_addr'), nested(item, 'video.downloadAddr'),
      nested(item, 'video.play_addr_h264'),
    );
    if (provider !== 'tikhub-youtube' && !playUrl) return [];
    const duration = Number(item.duration ?? nested(item, 'video.duration'));
    const playCount = item.play_count ?? nested(item, 'statistics.play_count') ?? nested(item, 'statistics.playCount') ?? item.views;
    const metrics = [Number.isFinite(duration) && duration > 0 ? `${duration > 1000 ? Math.round(duration / 1000) : Math.round(duration)} 秒` : '', compactCount(playCount)].filter(Boolean);
    const token = encodeShortToken(provider, id);
    return [{
      id: `${provider}-${id}`,
      sourceId: source.id,
      sourceName: authorName ? `${platform} · ${authorName}` : platform,
      title: text(item.desc ?? item.title ?? item.video_description) || `${platform} ${id}`,
      poster,
      category: 'short',
      summary: text(item.desc ?? item.description ?? item.title),
      remarks: metrics.join(' · '),
      playLines: provider === 'tikhub-youtube'
        ? directLine(source, token)
        : directLine(source, playUrl, provider === 'tikhub-tiktok' ? { Referer: 'https://www.tiktok.com/' } : { Referer: 'https://www.douyin.com/' }),
      quality: '自适应',
    }];
  });
}

function baseUrl(source: CmsSource): string {
  return (source.api ?? '').replace(/\/$/, '');
}

function tikHubHeaders(source: CmsSource): Record<string, string> {
  const authorization = source.headers?.Authorization ?? source.headers?.authorization ?? '';
  if (!/^Bearer\s+\S+/i.test(authorization)) throw new Error('请先在设置中填写 TikHub Token');
  return { ...source.headers, Authorization: authorization, Accept: 'application/json', 'Content-Type': 'application/json' };
}

function parsePayload(raw: string): unknown {
  const payload = JSON.parse(raw) as JsonRecord;
  const code = Number(payload.code ?? 0);
  if (code && code !== 200) throw new Error(text(payload.message ?? payload.msg) || `平台接口错误 ${code}`);
  return payload;
}

async function searchTikWm(source: CmsSource, page: number): Promise<ShortSourcePage> {
  const key = `${source.id}:${source.region || 'US'}:${page}`;
  const cached = tikWmCache.get(key);
  const now = Date.now();
  if (cached && now - cached.storedAt < TIKWM_CACHE_MS) return cached.value;

  const pending = tikWmPending.get(key);
  if (pending) return pending;

  const request = (async () => {
    const waitMs = Math.max(0, TIKWM_MIN_INTERVAL_MS - (Date.now() - lastTikWmRequestAt));
    if (waitMs) await new Promise((resolve) => setTimeout(resolve, waitMs));
    lastTikWmRequestAt = Date.now();
    const url = new URL('/api/feed/list', baseUrl(source));
    url.searchParams.set('region', source.region || 'US');
    url.searchParams.set('count', '12');
    if (page > 1) url.searchParams.set('cursor', String((page - 1) * 12));
    try {
      const payload = parsePayload(await fetchRemoteText(url.toString(), { timeoutMs: 20_000 }));
      const items = normalizeTikWmItems(payload, source);
      const value = { items, hasMore: items.length > 0 };
      tikWmCache.set(key, { value, storedAt: Date.now() });
      return value;
    } catch (error) {
      if (cached && now - cached.storedAt < TIKWM_STALE_MS) return cached.value;
      throw error;
    }
  })();
  tikWmPending.set(key, request);
  try {
    return await request;
  } finally {
    tikWmPending.delete(key);
  }
}

export async function searchShortSource(source: CmsSource, query: string, page: number): Promise<ShortSourcePage> {
  const provider = source.provider;
  if (!provider || !source.api) return { items: [], hasMore: false };
  if (provider === 'tikwm') {
    return searchTikWm(source, page);
  }

  const headers = tikHubHeaders(source);
  if (provider === 'tikhub-douyin') {
    const payload = parsePayload(await fetchRemoteText(`${baseUrl(source)}/api/v1/douyin/web/fetch_home_feed`, {
      method: 'POST', headers, body: JSON.stringify({ count: 10, refresh_index: page - 1 }), timeoutMs: 30_000,
    }));
    const items = normalizeTikHubItems(payload, source);
    return { items, hasMore: items.length > 0 };
  }
  if (provider === 'tikhub-tiktok') {
    const payload = parsePayload(await fetchRemoteText(`${baseUrl(source)}/api/v1/tiktok/web/fetch_home_feed`, {
      method: 'POST', headers, body: JSON.stringify({ count: 15, region: source.region || 'US' }), timeoutMs: 30_000,
    }));
    const items = normalizeTikHubItems(payload, source);
    return { items, hasMore: items.length > 0 };
  }

  const key = `${source.id}:${query.trim() || '热门'}`;
  const tokens = youtubePageTokens.get(key) ?? [''];
  if (page > 1 && !tokens[page - 1]) return { items: [], hasMore: false };
  const url = new URL(`${baseUrl(source)}/api/v1/youtube/web_v2/get_shorts_search_v2`);
  url.searchParams.set('keyword', query.trim() || '热门');
  url.searchParams.set('sort_by', 'view_count');
  if (page > 1) url.searchParams.set('continuation_token', tokens[page - 1]);
  const payload = parsePayload(await fetchRemoteText(url.toString(), { headers, timeoutMs: 30_000 }));
  const nextToken = findText(payload, ['continuation_token', 'continuationToken', 'nextpage', 'nextPageToken']);
  tokens[page] = nextToken;
  youtubePageTokens.set(key, tokens);
  return { items: normalizeTikHubItems(payload, source), hasMore: Boolean(nextToken) };
}

export async function resolveShortPlayback(source: CmsSource, token: string): Promise<PlaybackResolution> {
  const decoded = decodeShortToken(token);
  if (decoded.provider !== 'tikhub-youtube' || source.provider !== decoded.provider) {
    throw new Error('短视频播放来源不匹配');
  }
  const url = new URL(`${baseUrl(source)}/api/v1/youtube/web_v2/get_video_streams_v2`);
  url.searchParams.set('video_id', decoded.videoId);
  const payload = parsePayload(await fetchRemoteText(url.toString(), { headers: tikHubHeaders(source), timeoutMs: 45_000 }));
  const formats = findArray(payload, ['formats']).map(record).filter((item) => firstUrl(item.url));
  formats.sort((left, right) => Number(right.height ?? right.bitrate ?? 0) - Number(left.height ?? left.bitrate ?? 0));
  const stream = firstUrl(formats[0]?.url, findText(payload, ['hls_manifest_url', 'hlsManifestUrl']));
  if (!stream) throw new Error('YouTube Shorts 没有可用的音视频合并流');
  return { url: stream };
}

export async function testShortSource(source: CmsSource): Promise<void> {
  const response = await searchShortSource(source, '', 1);
  if (!response.items.length) throw new Error('接口没有返回可播放短视频');
}
