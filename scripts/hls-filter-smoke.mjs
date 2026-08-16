import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { createServer } from 'node:http';
import { createServer as createTcpServer } from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { filterHlsManifest } from '../dist-electron/hls-filter.js';
import { startProxyServer } from '../dist-electron/proxy-server.js';
import { VideoCache } from '../dist-electron/video-cache.js';

const fixture = `#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:5
#EXT-X-MEDIA-SEQUENCE:10
#EXT-X-DATERANGE:ID="break",CLASS="com.apple.hls.interstitial",X-ASSET-URI="ad-break.m3u8"
#EXTINF:5,
preroll/ad-0.ts
#EXTINF:5,
main/1.ts
#EXT-X-CUE-OUT:10
#EXTINF:5,
ads/mid-1.ts
#EXTINF:5,
ads/mid-2.ts
#EXT-X-CUE-IN
#EXTINF:5,
main/2.ts
#EXT-X-ENDLIST`;

const filtered = filterHlsManifest(fixture);
assert.equal(filtered.removedSegments, 3);
assert.equal(filtered.removedDuration, 15);
assert(filtered.removedMarkers >= 3);
assert(filtered.manifest.includes('#EXT-X-MEDIA-SEQUENCE:11'));
assert(filtered.manifest.includes('main/1.ts') && filtered.manifest.includes('main/2.ts'));
assert(!filtered.manifest.includes('ad-0.ts') && !filtered.manifest.includes('mid-1.ts'));
assert(filtered.manifest.includes('#EXT-X-DISCONTINUITY'));
const falsePositive = filterHlsManifest(`#EXTM3U
#EXTINF:5,
pcdn/main-adsorption.ts
#EXTINF:5,
media/shadow-play.ts`);
assert.equal(falsePositive.removedSegments, 0);
const encrypted = filterHlsManifest(`#EXTM3U
#EXT-X-MEDIA-SEQUENCE:3
#EXT-X-KEY:METHOD=AES-128,URI="keys/content.key"
#EXT-X-MAP:URI="init/content.mp4"
#EXTINF:5,
ads/preroll.ts
#EXTINF:5,
main/first.m4s`);
assert(encrypted.manifest.includes('#EXT-X-KEY:METHOD=AES-128,URI="keys/content.key"'));
assert(encrypted.manifest.includes('#EXT-X-MAP:URI="init/content.mp4"'));
assert(encrypted.manifest.indexOf('#EXT-X-KEY:') < encrypted.manifest.indexOf('main/first.m4s'));

const cancelledStreams = new Map();
const upstream = createServer((request, response) => {
  if (request.url === '/playlist.m3u8') {
    response.writeHead(200, { 'Content-Type': 'application/vnd.apple.mpegurl' }).end(fixture);
    return;
  }
  if (request.url?.startsWith('/slow.ts')) {
    const caseId = new URL(request.url, 'http://127.0.0.1').searchParams.get('case');
    let completed = false;
    let resolveCancelled;
    const cancelled = new Promise((resolve) => { resolveCancelled = resolve; });
    cancelledStreams.set(caseId, cancelled);
    response.writeHead(200, { 'Content-Type': 'video/mp2t' });
    response.write(Buffer.alloc(64 * 1024, 3));
    const interval = setInterval(() => response.write(Buffer.alloc(64 * 1024, 3)), 20);
    response.once('close', () => {
      clearInterval(interval);
      if (!completed) resolveCancelled();
    });
    setTimeout(() => {
      if (response.destroyed) return;
      completed = true;
      clearInterval(interval);
      response.end();
    }, 10_000);
    return;
  }
  response.writeHead(200, { 'Content-Type': 'video/mp2t' }).end(Buffer.alloc(24_000, 7));
});
await new Promise((resolve) => upstream.listen(0, '127.0.0.1', resolve));
const upstreamAddress = upstream.address();
assert(upstreamAddress && typeof upstreamAddress === 'object');
const target = `http://127.0.0.1:${upstreamAddress.port}/playlist.m3u8`;
const cache = await mkdtemp(path.join(os.tmpdir(), 'videoget-hls-smoke-'));
const videoCache = new VideoCache(path.join(cache, 'video'));
await videoCache.init();
const desktop = await startProxyServer(path.join(cache, 'images'), videoCache);

function freePort() {
  return new Promise((resolve, reject) => {
    const server = createTcpServer();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      server.close(() => resolve(address.port));
    });
  });
}

async function waitFor(origin, child) {
  for (let index = 0; index < 80; index++) {
    if (child.exitCode !== null) throw new Error('Web 服务提前退出');
    try { if ((await fetch(origin)).ok) return; } catch {}
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error('Web 服务启动超时');
}

async function abortStream(url, caseId) {
  const controller = new AbortController();
  const response = await fetch(url, { signal: controller.signal });
  const reader = response.body.getReader();
  const first = await reader.read();
  assert(first.value?.byteLength > 0, `${caseId} stream must yield data before cancellation`);
  controller.abort();
  await Promise.race([
    cancelledStreams.get(caseId),
    new Promise((_, reject) => setTimeout(() => reject(new Error(`${caseId} upstream stream was not cancelled`)), 3_000)),
  ]);
}

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const nextPort = await freePort();
const origin = `http://127.0.0.1:${nextPort}`;
const nextBin = path.join(root, 'node_modules', 'next', 'dist', 'bin', 'next');
const child = spawn(process.execPath, [nextBin, 'start', 'web', '--hostname', '127.0.0.1', '--port', String(nextPort)], {
  cwd: root, windowsHide: true, stdio: 'ignore',
});

try {
  const desktopResponse = await fetch(`http://127.0.0.1:${desktop.port}/stream?url=${encodeURIComponent(target)}&filterAds=1`);
  const desktopManifest = await desktopResponse.text();
  assert.equal(desktopResponse.headers.get('x-videoget-ad-segments'), '3');
  assert(desktopManifest.includes('filterAds=1') && !desktopManifest.includes('mid-1.ts'));
  const desktopSegment = desktopManifest.split(/\r?\n/).find((line) => line.startsWith('http://127.0.0.1:'));
  assert(desktopSegment);
  const firstSegment = await fetch(desktopSegment);
  assert.equal(firstSegment.headers.get('x-videoget-cache'), 'MISS');
  assert.equal((await firstSegment.arrayBuffer()).byteLength, 24_000);
  for (let index = 0; index < 20 && !videoCache.count; index++) await new Promise((resolve) => setTimeout(resolve, 25));
  const cachedSegment = await fetch(desktopSegment);
  assert.equal(cachedSegment.headers.get('x-videoget-cache'), 'HIT');
  assert.equal((await cachedSegment.arrayBuffer()).byteLength, 24_000);
  const rangeTarget = `http://127.0.0.1:${upstreamAddress.port}/slow.ts?case=range`;
  const rangeUrl = `http://127.0.0.1:${desktop.port}/stream?url=${encodeURIComponent(rangeTarget)}`;
  const rangeHeaders = { Range: 'bytes=0-65535' };
  const firstRange = await fetch(rangeUrl, { headers: rangeHeaders });
  assert.equal(firstRange.headers.get('x-videoget-cache'), 'MISS');
  await firstRange.arrayBuffer();
  for (let index = 0; index < 20 && videoCache.count < 2; index++) await new Promise((resolve) => setTimeout(resolve, 25));
  const cachedRange = await fetch(rangeUrl, { headers: rangeHeaders });
  assert.equal(cachedRange.status, 206);
  assert.equal(cachedRange.headers.get('x-videoget-cache'), 'HIT');
  assert.match(cachedRange.headers.get('content-range') ?? '', /^bytes 0-/);
  await cachedRange.arrayBuffer();
  const desktopSlowTarget = `http://127.0.0.1:${upstreamAddress.port}/slow.ts?case=desktop`;
  await abortStream(`http://127.0.0.1:${desktop.port}/stream?url=${encodeURIComponent(desktopSlowTarget)}`, 'desktop');

  await waitFor(origin, child);
  const webResponse = await fetch(`${origin}/api/proxy?url=${encodeURIComponent(target)}&filterAds=1`);
  const webManifest = await webResponse.text();
  assert.equal(webResponse.headers.get('x-videoget-ad-segments'), '3');
  assert(webManifest.includes('filterAds=1') && !webManifest.includes('mid-2.ts'));
  const webSegment = webManifest.split(/\r?\n/).find((line) => line.startsWith('/api/proxy?'));
  assert(webSegment && (await (await fetch(`${origin}${webSegment}`)).arrayBuffer()).byteLength === 24_000);
  const webSlowTarget = `http://127.0.0.1:${upstreamAddress.port}/slow.ts?case=web`;
  await abortStream(`${origin}/api/proxy?url=${encodeURIComponent(webSlowTarget)}`, 'web');

  const unfilteredResponse = await fetch(`${origin}/api/proxy?url=${encodeURIComponent(target)}`);
  const unfiltered = await unfilteredResponse.text();
  assert(unfiltered.includes('mid-1.ts'));
  console.log(JSON.stringify({
    removedSegments: 3,
    removedSeconds: 15,
    desktopBytes: 24_000,
    desktopCacheHit: true,
    desktopRangeCacheHit: true,
    webBytes: 24_000,
    desktopCancellation: true,
    webCancellation: true,
    optOutVerified: true,
  }, null, 2));
} finally {
  child.kill('SIGTERM');
  await desktop.close();
  await new Promise((resolve) => upstream.close(resolve));
  await rm(cache, { recursive: true, force: true });
}
