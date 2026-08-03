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

const upstream = createServer((request, response) => {
  if (request.url === '/playlist.m3u8') {
    response.writeHead(200, { 'Content-Type': 'application/vnd.apple.mpegurl' }).end(fixture);
    return;
  }
  response.writeHead(200, { 'Content-Type': 'video/mp2t' }).end(Buffer.alloc(24_000, 7));
});
await new Promise((resolve) => upstream.listen(0, '127.0.0.1', resolve));
const upstreamAddress = upstream.address();
assert(upstreamAddress && typeof upstreamAddress === 'object');
const target = `http://127.0.0.1:${upstreamAddress.port}/playlist.m3u8`;
const cache = await mkdtemp(path.join(os.tmpdir(), 'videoget-hls-smoke-'));
const desktop = await startProxyServer(cache);

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
  assert(desktopSegment && (await (await fetch(desktopSegment)).arrayBuffer()).byteLength === 24_000);

  await waitFor(origin, child);
  const webResponse = await fetch(`${origin}/api/proxy?url=${encodeURIComponent(target)}&filterAds=1`);
  const webManifest = await webResponse.text();
  assert.equal(webResponse.headers.get('x-videoget-ad-segments'), '3');
  assert(webManifest.includes('filterAds=1') && !webManifest.includes('mid-2.ts'));
  const webSegment = webManifest.split(/\r?\n/).find((line) => line.startsWith('/api/proxy?'));
  assert(webSegment && (await (await fetch(`${origin}${webSegment}`)).arrayBuffer()).byteLength === 24_000);

  const unfilteredResponse = await fetch(`${origin}/api/proxy?url=${encodeURIComponent(target)}`);
  const unfiltered = await unfilteredResponse.text();
  assert(unfiltered.includes('mid-1.ts'));
  console.log(JSON.stringify({ removedSegments: 3, removedSeconds: 15, desktopBytes: 24_000, webBytes: 24_000, optOutVerified: true }, null, 2));
} finally {
  child.kill('SIGTERM');
  await desktop.close();
  await new Promise((resolve) => upstream.close(resolve));
  await rm(cache, { recursive: true, force: true });
}
