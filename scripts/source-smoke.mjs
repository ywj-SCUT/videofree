import { mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { DEFAULT_SOURCES } from '../dist-electron/default-sources.js';
import { aggregateSearch, getDetail } from '../dist-electron/source-engine.js';
import { startProxyServer } from '../dist-electron/proxy-server.js';

const query = process.env.VIDEOGET_SMOKE_QUERY ?? '哪吒';
const requestedSources = process.argv.slice(2).map((entry, index) => {
  const splitAt = entry.indexOf('=');
  const name = splitAt > 0 ? entry.slice(0, splitAt) : `候选线路 ${index + 1}`;
  const api = splitAt > 0 ? entry.slice(splitAt + 1) : entry;
  return {
    id: `smoke-${index}`,
    name,
    type: 'cms',
    api,
    enabled: true,
    searchable: true,
  };
});
const sources = requestedSources.length ? requestedSources : DEFAULT_SOURCES;

function streamUrl(port, target) {
  return `http://127.0.0.1:${port}/stream?url=${encodeURIComponent(target)}`;
}

async function probeUrl(url, depth = 0) {
  if (depth > 3) throw new Error('HLS 清单嵌套超过 3 层');
  const response = await fetch(url, {
    headers: { Range: 'bytes=0-1048575' },
    signal: AbortSignal.timeout(18_000),
  });
  if (!response.ok && response.status !== 206) throw new Error(`HTTP ${response.status}`);
  const contentType = response.headers.get('content-type') ?? '';
  if (!/mpegurl/i.test(contentType)) {
    const bytes = (await response.arrayBuffer()).byteLength;
    if (bytes < 10_000) throw new Error(`媒体响应过小：${bytes} bytes`);
    return { depth, status: response.status, contentType, bytes };
  }

  const manifest = await response.text();
  if (!manifest.startsWith('#EXTM3U')) throw new Error('响应不是有效 HLS 清单');
  const candidates = manifest.split(/\r?\n/).map((line) => line.trim())
    .filter((line) => line && !line.startsWith('#'));
  if (!candidates.length) throw new Error('HLS 清单没有媒体项');
  let lastError;
  for (const candidate of candidates.slice(0, 4)) {
    try {
      return await probeUrl(new URL(candidate, url).toString(), depth + 1);
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError ?? new Error('HLS 媒体项均不可用');
}

function episodeCandidates(detail) {
  const candidates = [];
  for (const line of detail.playLines ?? []) {
    const episodes = line.episodes ?? [];
    if (episodes[0]) candidates.push({ line: line.name, episode: episodes[0] });
    if (episodes.length > 1) candidates.push({ line: line.name, episode: episodes.at(-1) });
  }
  return candidates.slice(0, 10);
}

async function smokeSource(source, port) {
  const search = await aggregateSearch([source], query, 'all');
  const items = search.items.filter((item) => item.sourceId === source.id);
  if (!items.length) throw new Error(`搜索“${query}”没有远程结果`);
  const attempts = [];

  for (const item of items.slice(0, 6)) {
    let detail;
    try {
      detail = await getDetail([source], source.id, item.id);
    } catch (error) {
      attempts.push(`${item.title}: 详情失败 ${error instanceof Error ? error.message : error}`);
      continue;
    }
    if (!detail) {
      attempts.push(`${item.title}: 无详情`);
      continue;
    }
    for (const candidate of episodeCandidates(detail)) {
      try {
        const media = await probeUrl(streamUrl(port, candidate.episode.url));
        return {
          source: source.name,
          searchItems: items.length,
          title: item.title,
          line: candidate.line,
          episode: candidate.episode.name,
          media,
        };
      } catch (error) {
        attempts.push(`${item.title}/${candidate.line}/${candidate.episode.name}: ${error instanceof Error ? error.message : error}`);
      }
    }
  }
  throw new Error(attempts.slice(-8).join(' | ') || '没有可探测的播放地址');
}

const cacheDirectory = await mkdtemp(path.join(os.tmpdir(), 'videoget-source-smoke-'));
const proxy = await startProxyServer(cacheDirectory);
const results = [];
let failed = false;
try {
  for (const source of sources) {
    const started = Date.now();
    try {
      const result = await smokeSource(source, proxy.port);
      results.push({ ok: true, elapsedMs: Date.now() - started, ...result });
    } catch (error) {
      failed = true;
      results.push({
        ok: false,
        source: source.name,
        elapsedMs: Date.now() - started,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }
} finally {
  await proxy.close();
  await rm(cacheDirectory, { recursive: true, force: true });
}

console.log(JSON.stringify({ query, results }, null, 2));
if (failed) process.exitCode = 1;
