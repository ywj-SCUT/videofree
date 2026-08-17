import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { createServer } from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { PrefetchManager } from '../dist-electron/prefetch-manager.js';
import { startProxyServer } from '../dist-electron/proxy-server.js';
import { VideoCache } from '../dist-electron/video-cache.js';

const segment = Buffer.alloc(32 * 1024, 9);
let activeSegments = 0;
let maxActiveSegments = 0;
let activeBackfillSegments = 0;
let maxActiveBackfillSegments = 0;
const requestedSegments = [];
const requestedManifests = [];
const priorityIndexes = new Set([0, 1, 2, 3, 4, 5, 75, 76, 150, 151]);
const upstream = createServer((request, response) => {
  if (request.url === '/master.m3u8') {
    response.writeHead(200, { 'Content-Type': 'application/vnd.apple.mpegurl' }).end(`#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
/low.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=12000000,RESOLUTION=3840x2160
/ultra.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
/playlist.m3u8`);
    return;
  }
  if (request.url === '/playlist.m3u8') {
    requestedManifests.push(request.url);
    const entries = Array.from({ length: 180 }, (_, index) => `#EXTINF:4,\n/segment-${index}.ts`).join('\n');
    response.writeHead(200, { 'Content-Type': 'application/vnd.apple.mpegurl' }).end(`#EXTM3U\n${entries}`);
    return;
  }
  if (request.url === '/low.m3u8' || request.url === '/ultra.m3u8') {
    requestedManifests.push(request.url);
    response.writeHead(200, { 'Content-Type': 'application/vnd.apple.mpegurl' }).end('#EXTM3U\n#EXTINF:4,\n/wrong-segment.ts');
    return;
  }
  if (request.url === '/failure.m3u8') {
    response.writeHead(200, { 'Content-Type': 'application/vnd.apple.mpegurl' }).end('#EXTM3U\n#EXTINF:4,\n/missing.ts');
    return;
  }
  if (request.url?.startsWith('/segment-')) {
    const segmentIndex = Number(request.url.match(/segment-(\d+)/)?.[1]);
    requestedSegments.push(segmentIndex);
    activeSegments++;
    maxActiveSegments = Math.max(maxActiveSegments, activeSegments);
    if (!priorityIndexes.has(segmentIndex)) {
      activeBackfillSegments++;
      maxActiveBackfillSegments = Math.max(maxActiveBackfillSegments, activeBackfillSegments);
    }
    setTimeout(() => {
      activeSegments--;
      if (!priorityIndexes.has(segmentIndex)) activeBackfillSegments--;
      response.writeHead(200, { 'Content-Type': 'video/mp2t', 'Content-Length': segment.length }).end(segment);
    }, 5);
    return;
  }
  response.writeHead(404).end();
});

await new Promise((resolve) => upstream.listen(0, '127.0.0.1', resolve));
const upstreamAddress = upstream.address();
assert(upstreamAddress && typeof upstreamAddress === 'object');
const target = `http://127.0.0.1:${upstreamAddress.port}/master.m3u8`;
const temp = await mkdtemp(path.join(os.tmpdir(), 'videoget-prefetch-smoke-'));
const cache = new VideoCache(path.join(temp, 'video'));
await cache.init();
const proxy = await startProxyServer(path.join(temp, 'images'), cache);

try {
  const manager = new PrefetchManager();
  await manager.start(target, proxy.port, { 'X-Playback-Test': '1' }, true);
  const progress = manager.currentProgress;
  assert.equal(progress.total, 180, '12 分钟清单应继续回填整集全部分片');
  assert.equal(progress.failed, 0);
  assert.equal(progress.fetched, 180);
  assert.deepEqual(requestedManifests, ['/playlist.m3u8'], '预取应选择不超过 1080p 的最高画质清单');
  assert(maxActiveSegments > 1 && maxActiveSegments <= 2, '预取上游并发必须限制为 2');
  assert.equal(maxActiveBackfillSegments, 1, '整集顺序回填必须使用单并发');
  assert(requestedSegments.indexOf(150) < requestedSegments.indexOf(6), '10 分钟锚点必须早于顺序回填');

  const params = new URLSearchParams({
    url: target,
    filterAds: '1',
    headers: JSON.stringify({ 'X-Playback-Test': '1' }),
  });
  const master = await (await fetch(`http://127.0.0.1:${proxy.port}/stream?${params}`)).text();
  const mediaUrl = master.split(/\r?\n/).find((line) => line.includes('/stream?') && line.includes('playlist.m3u8'));
  assert(mediaUrl);
  const manifest = await (await fetch(mediaUrl)).text();
  const firstSegmentUrl = manifest.split(/\r?\n/).find((line) => line.includes('/stream?') && line.includes('segment-0.ts'));
  const tenMinuteSegmentUrl = manifest.split(/\r?\n/).find((line) => line.includes('/stream?') && line.includes('segment-150.ts'));
  assert(firstSegmentUrl);
  assert(tenMinuteSegmentUrl);
  const cached = await fetch(firstSegmentUrl);
  assert.equal(cached.headers.get('x-videoget-cache'), 'HIT', '预取与实际播放必须使用相同缓存键');
  assert.equal((await cached.arrayBuffer()).byteLength, segment.length);
  const tenMinuteCached = await fetch(tenMinuteSegmentUrl);
  assert.equal(tenMinuteCached.headers.get('x-videoget-cache'), 'HIT', '10 分钟跳播锚点必须已经预热');
  assert.equal((await tenMinuteCached.arrayBuffer()).byteLength, segment.length);

  const failedManager = new PrefetchManager();
  await failedManager.start(`http://127.0.0.1:${upstreamAddress.port}/failure.m3u8`, proxy.port);
  assert.equal(failedManager.currentProgress.failed, 1, '空预取响应必须计为失败');
  assert.equal(failedManager.currentProgress.fetched, 0);

  const topLevelFailure = new PrefetchManager();
  await topLevelFailure.start(`http://127.0.0.1:${upstreamAddress.port}/missing-master.m3u8`, proxy.port);
  assert.equal(topLevelFailure.currentProgress.status, 'failed', '清单获取异常必须标记失败');

  console.log(JSON.stringify({
    prefetchedSegments: progress.fetched,
    selectedSegments: progress.total,
    cacheEntries: cache.count,
    playbackCacheHit: true,
    tenMinuteSeekCacheHit: true,
    fullEpisodeCached: cache.count === 180,
    maxActiveSegments,
    maxActiveBackfillSegments,
    selectedVariant: requestedManifests[0],
    failedPrefetchesDetected: true,
  }, null, 2));
} finally {
  await proxy.close();
  await new Promise((resolve) => upstream.close(resolve));
  await rm(temp, { recursive: true, force: true });
}
