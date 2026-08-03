import { XMLParser } from 'fast-xml-parser';
import { fetchRemoteText } from './net-client.js';
import type { DanmakuComment, DanmakuMatch, DanmakuProvider, DanmakuResponse } from './types.js';

const bilibiliHeaders = { Referer: 'https://www.bilibili.com/' };
const xmlParser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: '',
  textNodeName: '#text',
});

function cleanTitle(value: string): string {
  return value.replace(/<[^>]+>/g, '').replace(/&[^;]+;/g, ' ').trim();
}

function normalized(value: string): string {
  return cleanTitle(value).toLowerCase().replace(/[\s\p{P}\p{S}]+/gu, '');
}

function titleScore(candidate: string, query: string): number {
  const left = normalized(candidate);
  const right = normalized(query);
  if (!left || !right) return 0;
  if (left === right) return 100;
  if (left.includes(right)) return 85;
  if (right.includes(left)) return 75;
  return 0;
}

function episodeNumber(value: string): string | null {
  const matched = value.match(/(?:第\s*)?(\d+(?:\.\d+)?)(?:\s*[集话期])?/);
  if (!matched) return null;
  const parsed = Number(matched[1]);
  return Number.isFinite(parsed) ? String(parsed) : null;
}

function selectEpisode<T extends { title?: string | number; long_title?: string; episodeTitle?: string }>(episodes: T[], name: string): T | undefined {
  const target = normalized(name);
  const number = episodeNumber(name);
  return episodes.find((episode) => {
    const values = [String(episode.title ?? ''), episode.long_title ?? '', episode.episodeTitle ?? ''];
    return values.some((value) => normalized(value) === target)
      || Boolean(number && values.some((value) => episodeNumber(value) === number));
  }) ?? episodes[0];
}

function colorHex(value: unknown): string {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? `#${Math.max(0, Math.min(0xffffff, parsed)).toString(16).padStart(6, '0')}` : '#ffffff';
}

function mode(value: unknown): 0 | 1 | 2 {
  const parsed = Number(value);
  if (parsed === 5) return 1;
  if (parsed === 4) return 2;
  return 0;
}

export function parseDanmakuXml(xml: string, source: string): DanmakuComment[] {
  const document = xmlParser.parse(xml) as { i?: { d?: unknown | unknown[] } };
  const nodes = document.i?.d == null ? [] : Array.isArray(document.i.d) ? document.i.d : [document.i.d];
  return nodes.flatMap((node) => {
    if (!node || typeof node !== 'object') return [];
    const value = node as Record<string, unknown>;
    const parts = String(value.p ?? '').split(',');
    const text = String(value['#text'] ?? '').trim();
    const time = Number(parts[0]);
    if (!text || text.length > 160 || !Number.isFinite(time) || time < 0 || time > 21_600) return [];
    return [{ text, time, mode: mode(parts[1]), color: colorHex(parts[3]), source }];
  });
}

export function mergeDanmakuComments(groups: DanmakuComment[][]): DanmakuComment[] {
  const seen = new Set<string>();
  return groups.flat().filter((comment) => {
    const key = `${normalized(comment.text)}:${Math.round(comment.time * 2)}`;
    if (!normalized(comment.text) || seen.has(key)) return false;
    seen.add(key);
    return true;
  }).sort((left, right) => left.time - right.time).slice(0, 12_000);
}

async function fetchBilibili(provider: DanmakuProvider, title: string, episodeName: string): Promise<{ comments: DanmakuComment[]; matches: DanmakuMatch[] }> {
  const base = (provider.api || 'https://api.bilibili.com').replace(/\/$/, '');
  const searchUrl = `${base}/x/web-interface/search/type?search_type=media_bangumi&keyword=${encodeURIComponent(title)}`;
  const search = JSON.parse(await fetchRemoteText(searchUrl, { headers: bilibiliHeaders })) as {
    code?: number;
    data?: { result?: Array<{ title?: string; season_id?: number }> };
  };
  if (search.code !== 0) throw new Error(`搜索接口返回 ${search.code ?? '未知状态'}`);
  const seasons = (search.data?.result ?? [])
    .filter((entry) => entry.season_id && titleScore(entry.title ?? '', title) >= 75)
    .sort((left, right) => titleScore(right.title ?? '', title) - titleScore(left.title ?? '', title))
    .slice(0, 2);
  const groups: DanmakuComment[][] = [];
  const matches: DanmakuMatch[] = [];

  for (const season of seasons) {
    const sectionUrl = `${base}/pgc/web/season/section?season_id=${season.season_id}`;
    const section = JSON.parse(await fetchRemoteText(sectionUrl, { headers: bilibiliHeaders })) as {
      code?: number;
      result?: {
        main_section?: { episodes?: Array<{ title?: string | number; long_title?: string; cid?: number }> };
        section?: Array<{ episodes?: Array<{ title?: string | number; long_title?: string; cid?: number }> }>;
      };
    };
    if (section.code !== 0) continue;
    const episodes = [
      ...(section.result?.main_section?.episodes ?? []),
      ...(section.result?.section ?? []).flatMap((entry) => entry.episodes ?? []),
    ];
    const episode = selectEpisode(episodes, episodeName);
    if (!episode?.cid) continue;
    const comments = parseDanmakuXml(await fetchRemoteText(`https://comment.bilibili.com/${episode.cid}.xml`, {
      headers: bilibiliHeaders,
      maxBytes: 12 * 1024 * 1024,
    }), provider.name);
    if (!comments.length) continue;
    groups.push(comments);
    matches.push({ providerId: provider.id, providerName: provider.name, title: cleanTitle(season.title ?? title), episode: `${episode.title ?? episodeName}${episode.long_title ? ` ${episode.long_title}` : ''}`.trim(), count: comments.length });
  }
  return { comments: mergeDanmakuComments(groups), matches };
}

function parseJsonComments(payload: unknown, source: string): DanmakuComment[] {
  const comments = (payload as { comments?: Array<{ p?: string; m?: string; text?: string; time?: number; mode?: number; color?: number | string }> })?.comments ?? [];
  return comments.flatMap((comment) => {
    const parts = String(comment.p ?? '').split(',');
    const text = String(comment.m ?? comment.text ?? '').trim();
    const time = Number(comment.time ?? parts[0]);
    if (!text || text.length > 160 || !Number.isFinite(time) || time < 0 || time > 21_600) return [];
    return [{ text, time, mode: mode(comment.mode ?? parts[1]), color: colorHex(comment.color ?? parts[2]), source }];
  });
}

async function fetchCompatible(provider: DanmakuProvider, title: string, episodeName: string): Promise<{ comments: DanmakuComment[]; matches: DanmakuMatch[] }> {
  if (!provider.api) throw new Error('缺少兼容 API 地址');
  const base = provider.api.replace(/\/$/, '').replace(/\/api\/v2$/i, '');
  const searchPayload = JSON.parse(await fetchRemoteText(`${base}/api/v2/search/episodes`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ anime: title, episode: episodeName }),
  })) as {
    animes?: Array<{ animeTitle?: string; episodes?: Array<{ episodeId?: number; episodeTitle?: string }> }>;
  };
  const anime = (searchPayload.animes ?? [])
    .filter((entry) => titleScore(entry.animeTitle ?? '', title) >= 75)
    .sort((left, right) => titleScore(right.animeTitle ?? '', title) - titleScore(left.animeTitle ?? '', title))[0];
  const episode = selectEpisode(anime?.episodes ?? [], episodeName);
  if (!episode?.episodeId) return { comments: [], matches: [] };
  const content = await fetchRemoteText(`${base}/api/v2/comment/${episode.episodeId}?format=json&withRelated=true&chConvert=1`, { maxBytes: 12 * 1024 * 1024 });
  const comments = content.trim().startsWith('<') ? parseDanmakuXml(content, provider.name) : parseJsonComments(JSON.parse(content), provider.name);
  return {
    comments,
    matches: comments.length ? [{ providerId: provider.id, providerName: provider.name, title: anime?.animeTitle ?? title, episode: episode.episodeTitle ?? episodeName, count: comments.length }] : [],
  };
}

export async function aggregateDanmaku(providers: DanmakuProvider[], title: string, episodeName: string): Promise<DanmakuResponse> {
  const startedAt = Date.now();
  const enabled = providers.filter((provider) => provider.enabled);
  const settled = await Promise.allSettled(enabled.map((provider) => provider.type === 'bilibili'
    ? fetchBilibili(provider, title, episodeName)
    : fetchCompatible(provider, title, episodeName)));
  const groups: DanmakuComment[][] = [];
  const matches: DanmakuMatch[] = [];
  const failures: DanmakuResponse['failures'] = [];
  settled.forEach((result, index) => {
    if (result.status === 'fulfilled') {
      groups.push(result.value.comments);
      matches.push(...result.value.matches);
    } else {
      failures.push({ providerId: enabled[index].id, providerName: enabled[index].name, message: result.reason instanceof Error ? result.reason.message : String(result.reason) });
    }
  });
  return { comments: mergeDanmakuComments(groups), matches, failures, elapsedMs: Date.now() - startedAt };
}
