import assert from 'node:assert/strict';
import { mkdtemp } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { DEFAULT_SOURCES } from '../dist-electron/default-sources.js';
import { startProxyServer } from '../dist-electron/proxy-server.js';
import { aggregateSearch, resolveMedia, routePlayLines } from '../dist-electron/source-engine.js';
import { VideoCache } from '../dist-electron/video-cache.js';

function firstEntry(manifest) {
  return manifest.split(/\r?\n/).map((line) => line.trim()).find((line) => line && !line.startsWith('#'));
}

function isManifestProxyUrl(value) {
  try {
    const parsed = new URL(value);
    return (parsed.searchParams.get('url') ?? value).toLowerCase().includes('.m3u8');
  } catch {
    return value.toLowerCase().includes('.m3u8');
  }
}

const temp = await mkdtemp(path.join(os.tmpdir(), 'videoget-route-network-'));
const cache = new VideoCache(path.join(temp, 'video'));
await cache.init();
const proxy = await startProxyServer(path.join(temp, 'images'), cache);
const started = performance.now();

try {
  const search = await aggregateSearch(DEFAULT_SOURCES, '怪奇物语', 'series');
  const item = search.items.find((entry) => entry.title.includes('怪奇物语'));
  assert(item, `联网搜索未返回目标，失败源：${JSON.stringify(search.failures)}`);
  assert(search.elapsedMs < 5_000, `聚合搜索超过总预算：${search.elapsedMs}ms`);
  const detailStarted = performance.now();
  const detail = await resolveMedia(DEFAULT_SOURCES, item);
  const detailElapsedMs = performance.now() - detailStarted;
  assert(detail?.playLines?.length >= 2, '详情没有足够线路用于路由');
  assert(detailElapsedMs < 6_000, `详情聚合超过截止预算：${Math.round(detailElapsedMs)}ms`);

  const episodeName = detail.playLines[0].episodes[0]?.name ?? '';
  const routed = await routePlayLines(DEFAULT_SOURCES, detail.playLines, episodeName, 0, proxy.port, true);
  const episode = routed[0].episodes[0];
  assert(episode && /^https?:\/\//i.test(episode.url), '优先线路首集不是可探测直链');

  const params = new URLSearchParams({ url: episode.url, filterAds: '1' });
  if (episode.headers && Object.keys(episode.headers).length) params.set('headers', JSON.stringify(episode.headers));
  let mediaUrl = `http://127.0.0.1:${proxy.port}/stream?${params}`;
  let response = await fetch(mediaUrl);
  assert(response.ok, `播放清单 HTTP ${response.status}`);
  let manifest = await response.text();
  mediaUrl = firstEntry(manifest);
  assert(mediaUrl, '播放清单没有媒体地址');
  if (isManifestProxyUrl(mediaUrl)) {
    response = await fetch(mediaUrl);
    assert(response.ok, `子清单 HTTP ${response.status}`);
    manifest = await response.text();
    mediaUrl = firstEntry(manifest);
    assert(mediaUrl, '子清单没有媒体分片');
  }
  const segmentResponse = await fetch(mediaUrl, { headers: { Range: 'bytes=0-131071' } });
  assert(segmentResponse.ok, `首分片 HTTP ${segmentResponse.status}`);
  const reader = segmentResponse.body?.getReader();
  const firstChunk = await reader?.read();
  assert(firstChunk?.value?.byteLength, '首分片没有返回数据');
  await reader?.cancel();

  console.log(JSON.stringify({
    title: item.title,
    searchElapsedMs: search.elapsedMs,
    detailElapsedMs: Math.round(detailElapsedMs),
    availableLines: detail.playLines.length,
    preferredLine: routed[0].name,
    preferredEpisode: episode.name,
    firstChunkBytes: firstChunk.value.byteLength,
    totalElapsedMs: Math.round(performance.now() - started),
    failures: search.failures,
    tempDirectory: temp,
  }, null, 2));
} finally {
  await proxy.close();
}
