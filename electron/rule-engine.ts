import { Worker } from 'node:worker_threads';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fetchRemoteText } from './net-client.js';
import type { CmsSource, MediaCategory, MediaItem, PlaybackResolution, PlayLine } from './types.js';

type RuleOperation = 'search' | 'detail' | 'play';

const scriptCache = new Map<string, { expiresAt: number; script: string }>();
const blockedScriptPattern = /\b(?:process|require|child_process|worker_threads|global\.process|Deno)\b|\bimport\s*\(|\beval\s*\(|\bFunction\s*\(/;
const blockedHeaders = new Set(['host', 'content-length', 'connection', 'proxy-authorization', 'transfer-encoding']);

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function text(value: unknown): string {
  return String(value ?? '').trim();
}

function normalizeHeaders(value: unknown): Record<string, string> | undefined {
  const entries = Object.entries(asRecord(value)).flatMap(([name, raw]) => {
    const normalized = name.trim().toLowerCase();
    if (!/^[a-z0-9-]{1,64}$/.test(normalized) || blockedHeaders.has(normalized)) return [];
    const headerValue = String(raw ?? '').trim();
    if (!headerValue || headerValue.length > 4096 || /[\r\n]/.test(headerValue)) return [];
    return [[name, headerValue] as const];
  });
  return entries.length ? Object.fromEntries(entries) : undefined;
}

function normalizeCategory(value: unknown): MediaCategory {
  const category = text(value) as MediaCategory;
  return ['movie', 'series', 'anime', 'short', 'ai-short', 'live'].includes(category) ? category : 'movie';
}

function encodeToken(value: unknown): string {
  return `videoget-rule:${Buffer.from(JSON.stringify(value)).toString('base64url')}`;
}

function decodeToken(value: string): unknown {
  if (!value.startsWith('videoget-rule:')) return value;
  const encoded = value.slice('videoget-rule:'.length);
  if (!encoded || encoded.length > 128_000) throw new Error('规则播放令牌无效');
  return JSON.parse(Buffer.from(encoded, 'base64url').toString('utf8'));
}

function normalizeEpisodes(value: unknown, sourceId: string): PlayLine[] {
  const record = asRecord(value);
  const rawLines = Array.isArray(record.playLines) ? record.playLines : [];
  return rawLines.flatMap((rawLine, lineIndex): PlayLine[] => {
    const line = asRecord(rawLine);
    const episodes = (Array.isArray(line.episodes) ? line.episodes : []).flatMap((rawEpisode, episodeIndex) => {
      const episode = asRecord(rawEpisode);
      const directUrl = text(episode.url);
      const hasToken = Object.prototype.hasOwnProperty.call(episode, 'token');
      if (!hasToken && !/^https?:\/\//i.test(directUrl)) return [];
      return [{
        name: text(episode.name) || `第 ${episodeIndex + 1} 集`,
        url: hasToken ? encodeToken(episode.token) : directUrl,
        sourceId,
        headers: normalizeHeaders(episode.headers),
      }];
    });
    return episodes.length ? [{ name: text(line.name) || `线路 ${lineIndex + 1}`, episodes }] : [];
  });
}

function normalizeItem(value: unknown, source: CmsSource, includePlayback: boolean): MediaItem | null {
  const item = asRecord(value);
  const id = text(item.id);
  const title = text(item.title);
  if (!id || !title) return null;
  return {
    id,
    sourceId: source.id,
    sourceName: source.name,
    title,
    poster: text(item.poster),
    backdrop: text(item.backdrop) || undefined,
    year: text(item.year),
    remarks: text(item.remarks),
    category: normalizeCategory(item.category),
    summary: text(item.summary),
    actors: text(item.actors),
    director: text(item.director),
    area: text(item.area),
    quality: text(item.quality) || undefined,
    playLines: includePlayback ? normalizeEpisodes(item, source.id) : [],
  };
}

async function sourceScript(source: CmsSource): Promise<string> {
  if (source.script) return source.script;
  if (!source.scriptUrl) throw new Error('规则源没有脚本');
  const cached = scriptCache.get(source.scriptUrl);
  if (cached && cached.expiresAt > Date.now()) return cached.script;
  const script = await fetchRemoteText(source.scriptUrl, { headers: source.headers, timeoutMs: 10_000, maxBytes: 200_000 });
  scriptCache.set(source.scriptUrl, { script, expiresAt: Date.now() + 5 * 60_000 });
  return script;
}

function validateScript(script: string): void {
  if (!script.trim()) throw new Error('规则脚本为空');
  if (Buffer.byteLength(script) > 200_000) throw new Error('规则脚本超过 200 KB');
  if (blockedScriptPattern.test(script)) throw new Error('规则包含被禁用的运行时能力');
}

async function runRule(source: CmsSource, operation: RuleOperation, input: unknown): Promise<unknown> {
  const script = await sourceScript(source);
  validateScript(script);
  return new Promise((resolve, reject) => {
    const adjacentUrl = new URL('./rule-worker.js', import.meta.url);
    const adjacentPath = decodeURIComponent(adjacentUrl.pathname).replace(/^\/(?=[A-Za-z]:[\\/])/, '');
    const workerPath = existsSync(adjacentPath)
      ? adjacentPath
      : path.resolve(process.cwd(), 'dist-electron', 'rule-worker.js');
    if (!existsSync(workerPath)) throw new Error('规则 Worker 尚未构建，请重新启动 VideoGET');
    const worker = new Worker(workerPath, {
      resourceLimits: { maxOldGenerationSizeMb: 32, maxYoungGenerationSizeMb: 8, stackSizeMb: 4 },
    });
    let finished = false;
    let requests = 0;
    const finish = (error?: Error, value?: unknown) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      void worker.terminate();
      if (error) reject(error); else resolve(value);
    };
    const timer = setTimeout(() => finish(new Error(`规则 ${operation} 执行超过 12 秒`)), 12_000);
    worker.on('error', (error) => finish(error));
    worker.on('exit', (code) => { if (!finished) finish(new Error(`规则 Worker 未返回结果 (${code})`)); });
    worker.on('message', async (message: Record<string, unknown>) => {
      if (message.type === 'result') return finish(undefined, message.value);
      if (message.type === 'error') return finish(new Error(text(message.error) || '规则执行失败'));
      if (message.type !== 'request') return;
      const id = Number(message.id);
      try {
        requests++;
        if (requests > 8) throw new Error('单次规则调用最多发起 8 个请求');
        const url = text(message.url);
        if (!/^https?:\/\//i.test(url)) throw new Error('规则仅可请求 HTTP/HTTPS 地址');
        const options = asRecord(message.options);
        const method = text(options.method).toUpperCase() || 'GET';
        if (!['GET', 'POST'].includes(method)) throw new Error('规则请求仅支持 GET/POST');
        const body = typeof options.body === 'string' ? options.body : undefined;
        if (body && Buffer.byteLength(body) > 256_000) throw new Error('规则请求体超过 256 KB');
        const response = await fetchRemoteText(url, {
          method,
          headers: { ...(source.headers ?? {}), ...(normalizeHeaders(options.headers) ?? {}) },
          body,
          timeoutMs: 8_000,
          maxBytes: 2 * 1024 * 1024,
        });
        worker.postMessage({ type: 'response', id, ok: true, body: response });
      } catch (error) {
        worker.postMessage({ type: 'response', id, ok: false, error: error instanceof Error ? error.message : String(error) });
      }
    });
    worker.postMessage({ type: 'start', script, operation, input, config: source.ruleConfig ?? {} });
  });
}

export async function searchRule(source: CmsSource, query: string): Promise<MediaItem[]> {
  const raw = await runRule(source, 'search', { query, page: 1 });
  const values = Array.isArray(raw) ? raw : Array.isArray(asRecord(raw).items) ? asRecord(raw).items as unknown[] : [];
  return values.map((value) => normalizeItem(value, source, false)).filter((value): value is MediaItem => Boolean(value));
}

export async function detailRule(source: CmsSource, id: string): Promise<MediaItem | null> {
  return normalizeItem(await runRule(source, 'detail', { id }), source, true);
}

export async function resolveRulePlayback(source: CmsSource, token: string): Promise<PlaybackResolution> {
  const raw = await runRule(source, 'play', { token: decodeToken(token) });
  if (typeof raw === 'string') {
    if (!/^https?:\/\//i.test(raw)) throw new Error('规则返回的播放地址无效');
    return { url: raw };
  }
  const result = asRecord(raw);
  const url = text(result.url);
  if (!/^https?:\/\//i.test(url)) throw new Error('规则返回的播放地址无效');
  return { url, headers: normalizeHeaders(result.headers) };
}

export async function testRule(source: CmsSource): Promise<void> {
  await searchRule(source, '测试');
}
