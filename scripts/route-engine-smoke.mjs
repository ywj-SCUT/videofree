import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { episodeForLine, rankRouteCandidates, rankRouteMetrics, scoreRouteMetrics } from '../dist-electron/route-engine.js';

const balanced = {
  ok: true,
  latencyMs: 900,
  width: 1080,
  height: 608,
  bandwidthMbps: 1.4,
  throughputMbps: 2.7,
};
const starvedHighResolution = {
  ok: true,
  latencyMs: 850,
  width: 1920,
  height: 960,
  bandwidthMbps: 2.8,
  throughputMbps: 1.3,
};
assert(scoreRouteMetrics(balanced) > scoreRouteMetrics(starvedHighResolution), '带宽不足的高分辨率线路不应优先');
assert.deepEqual(rankRouteMetrics([
  { index: 0, metrics: starvedHighResolution },
  { index: 1, metrics: balanced },
]), [1, 0]);
assert(scoreRouteMetrics(balanced, { attempts: 5, successes: 2, consecutiveFailures: 2 }) < scoreRouteMetrics(balanced));

const matched = episodeForLine({
  name: '备用线路',
  episodes: [
    { name: '第01集', url: 'https://example.test/1.m3u8' },
    { name: '第02集', url: 'https://example.test/2.m3u8' },
  ],
}, '2', 0);
assert.equal(matched?.name, '第02集', '同集切线应按集数匹配');

const segment = Buffer.alloc(256 * 1024, 7);
const fixture = createServer((request, response) => {
  if (request.url === '/fast/master.m3u8') {
    response.writeHead(200, { 'Content-Type': 'application/vnd.apple.mpegurl' }).end(`#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1600000,RESOLUTION=1280x720
/fast/media.m3u8`);
    return;
  }
  if (request.url === '/fast/media.m3u8') {
    response.writeHead(200, { 'Content-Type': 'application/vnd.apple.mpegurl' }).end(`#EXTM3U
#EXTINF:4,
/fast/segment.ts`);
    return;
  }
  if (request.url === '/fast/segment.ts') {
    response.writeHead(206, {
      'Content-Type': 'video/mp2t',
      'Content-Length': segment.length,
      'Content-Range': `bytes 0-${segment.length - 1}/${segment.length}`,
    }).end(segment);
    return;
  }
  if (request.url?.startsWith('/slow/master.m3u8')) {
    request.once('close', () => response.destroy());
    return;
  }
  response.writeHead(404).end();
});

await new Promise((resolve) => fixture.listen(0, '127.0.0.1', resolve));
const address = fixture.address();
assert(address && typeof address === 'object');
const origin = `http://127.0.0.1:${address.port}`;
const started = performance.now();
try {
  const order = await rankRouteCandidates([
    ...Array.from({ length: 7 }, (_, index) => ({
      index,
      name: `慢线路 ${index + 1}`,
      url: `${origin}/slow/master.m3u8?line=${index}`,
    })),
    { index: 7, name: '720P 稳定线路', url: `${origin}/fast/master.m3u8` },
  ], { proxyPort: 0, adFiltering: false, budgetMs: 650 });
  const elapsedMs = performance.now() - started;
  assert.equal(order[0], 7, '第 8 条实测成功线路也必须进入探测并排在超时线路前');
  assert(elapsedMs < 1_200, `总探测预算失效：${Math.round(elapsedMs)}ms`);
  console.log(JSON.stringify({
    balancedScore: Math.round(scoreRouteMetrics(balanced)),
    starvedHighResolutionScore: Math.round(scoreRouteMetrics(starvedHighResolution)),
    routeOrder: order,
    budgetElapsedMs: Math.round(elapsedMs),
    episodeMatch: matched?.name,
  }, null, 2));
} finally {
  await new Promise((resolve) => fixture.close(resolve));
}
