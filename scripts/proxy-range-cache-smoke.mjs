import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { createServer } from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { startProxyServer } from '../dist-electron/proxy-server.js';
import { VideoCache } from '../dist-electron/video-cache.js';

const content = Buffer.from(Array.from({ length: 100 }, (_, index) => index));
let ignoredRangeRequests = 0;
let validRangeRequests = 0;
const upstream = createServer((request, response) => {
  if (request.url === '/ignored-range.mp4') {
    ignoredRangeRequests++;
    response.writeHead(200, {
      'Content-Type': 'video/mp4',
      'Content-Length': content.length,
      'Accept-Ranges': 'bytes',
    }).end(content);
    return;
  }
  if (request.url === '/valid-range.mp4') {
    validRangeRequests++;
    const match = /^bytes=(\d+)-(\d*)$/i.exec(request.headers.range ?? '');
    assert(match);
    const start = Number(match[1]);
    const end = Math.min(match[2] ? Number(match[2]) : content.length - 1, content.length - 1);
    const body = content.subarray(start, end + 1);
    response.writeHead(206, {
      'Content-Type': 'video/mp4',
      'Content-Length': body.length,
      'Content-Range': `bytes ${start}-${end}/${content.length}`,
      'Accept-Ranges': 'bytes',
    }).end(body);
    return;
  }
  response.writeHead(404).end();
});

await new Promise((resolve) => upstream.listen(0, '127.0.0.1', resolve));
const upstreamAddress = upstream.address();
assert(upstreamAddress && typeof upstreamAddress === 'object');
const temp = await mkdtemp(path.join(os.tmpdir(), 'videoget-range-smoke-'));
const cache = new VideoCache(path.join(temp, 'video'));
await cache.init();
const proxy = await startProxyServer(path.join(temp, 'images'), cache);
const proxied = (name) => {
  const params = new URLSearchParams({
    url: `http://127.0.0.1:${upstreamAddress.port}/${name}`,
  });
  return `http://127.0.0.1:${proxy.port}/stream?${params}`;
};
const rangeHeaders = { Range: 'bytes=10-19' };

try {
  for (let attempt = 0; attempt < 2; attempt++) {
    const response = await fetch(proxied('ignored-range.mp4'), { headers: rangeHeaders });
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('x-videoget-cache'), null);
    assert.deepEqual(Buffer.from(await response.arrayBuffer()), content);
  }
  assert.equal(ignoredRangeRequests, 2, '忽略 Range 的 200 响应不得写入 Range 缓存');

  const first = await fetch(proxied('valid-range.mp4'), { headers: rangeHeaders });
  assert.equal(first.status, 206);
  assert.deepEqual(Buffer.from(await first.arrayBuffer()), content.subarray(10, 20));
  for (let attempt = 0; attempt < 20 && cache.count === 0; attempt++) {
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  assert.equal(cache.count, 1);

  const second = await fetch(proxied('valid-range.mp4'), { headers: rangeHeaders });
  assert.equal(second.status, 206);
  assert.equal(second.headers.get('x-videoget-cache'), 'HIT');
  assert.equal(second.headers.get('content-range'), 'bytes 10-19/*');
  assert.deepEqual(Buffer.from(await second.arrayBuffer()), content.subarray(10, 20));
  assert.equal(validRangeRequests, 1, '有效 206 响应应在第二次请求直接命中缓存');

  console.log(JSON.stringify({
    ignoredRangeCached: false,
    validPartialCacheHit: true,
    ignoredRangeRequests,
    validRangeRequests,
  }, null, 2));
} finally {
  await proxy.close();
  await new Promise((resolve) => upstream.close(resolve));
  await rm(temp, { recursive: true, force: true });
}
