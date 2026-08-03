import { readFile, mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { parseLivePlaylist } from '../dist-electron/live-engine.js';
import { startProxyServer } from '../dist-electron/proxy-server.js';

async function probe(url, depth = 0) {
  if (depth > 3) throw new Error('HLS 清单嵌套超过 3 层');
  const response = await fetch(url, { headers: { Range: 'bytes=0-1048575' }, signal: AbortSignal.timeout(18_000) });
  if (!response.ok && response.status !== 206) throw new Error(`HTTP ${response.status}`);
  const contentType = response.headers.get('content-type') ?? '';
  if (!/mpegurl/i.test(contentType)) {
    const bytes = (await response.arrayBuffer()).byteLength;
    if (bytes < 10_000) throw new Error(`媒体响应过小：${bytes} bytes`);
    return { status: response.status, contentType, bytes, depth };
  }
  const manifest = await response.text();
  if (!manifest.startsWith('#EXTM3U')) throw new Error('响应不是有效 HLS 清单');
  const entries = manifest.split(/\r?\n/).map((line) => line.trim()).filter((line) => line && !line.startsWith('#'));
  let lastError;
  for (const entry of entries.slice(0, 4)) {
    try {
      return await probe(new URL(entry, url).toString(), depth + 1);
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError ?? new Error('HLS 清单没有可用媒体项');
}

const fixture = path.resolve('tests/fixtures/live-smoke.m3u');
const content = await readFile(fixture, 'utf8');
const channels = parseLivePlaylist(content, 'smoke-live', '直播冒烟测试');
if (channels.length !== 1) throw new Error(`预期合并为 1 个频道，实际为 ${channels.length}`);
if (channels[0].urls?.length !== 2) throw new Error(`预期 2 条播放线路，实际为 ${channels[0].urls?.length ?? 0}`);

const cacheDirectory = await mkdtemp(path.join(os.tmpdir(), 'videoget-live-smoke-'));
const proxy = await startProxyServer(cacheDirectory);
try {
  const media = await probe(`http://127.0.0.1:${proxy.port}/stream?url=${encodeURIComponent(channels[0].url)}`);
  console.log(JSON.stringify({ channel: channels[0].name, group: channels[0].group, routes: channels[0].urls.length, media }, null, 2));
} finally {
  await proxy.close();
  await rm(cacheDirectory, { recursive: true, force: true });
}
