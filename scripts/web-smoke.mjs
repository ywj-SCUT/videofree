import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const nextBin = path.join(root, 'node_modules', 'next', 'dist', 'bin', 'next');
const sources = [
  { id: 'builtin-line-a', name: '默认线路 A', type: 'cms', api: 'https://caiji.moduapi.cc/api.php/provide/vod/', enabled: true, searchable: true },
  { id: 'builtin-line-b', name: '默认线路 B', type: 'cms', api: 'https://jszyapi.com/api.php/provide/vod/', enabled: true, searchable: true },
];

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

async function freePort() {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      server.close(() => resolve(address.port));
    });
  });
}

async function waitForServer(origin, child, logs) {
  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error(`Web 服务提前退出\n${logs.join('')}`);
    try {
      const response = await fetch(origin);
      if (response.ok) return;
    } catch {
      // Continue until the production server is ready.
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`等待 Web 服务超时\n${logs.join('')}`);
}

async function post(origin, route, body) {
  const response = await fetch(`${origin}${route}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
  });
  const payload = await response.json();
  if (!response.ok) throw new Error(`${route}: ${payload.error ?? `HTTP ${response.status}`}`);
  return payload;
}

const port = await freePort();
const origin = `http://127.0.0.1:${port}`;
const logs = [];
const child = spawn(process.execPath, [nextBin, 'start', 'web', '--hostname', '127.0.0.1', '--port', String(port)], {
  cwd: root, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'],
});
child.stdout.on('data', (chunk) => logs.push(chunk.toString()));
child.stderr.on('data', (chunk) => logs.push(chunk.toString()));

try {
  await waitForServer(origin, child, logs);

  const search = await post(origin, '/api/search', { query: '哪吒', category: 'all', sources });
  const merged = search.items.find((item) => item.title === '哪吒之魔童闹海');
  assert(search.items.length >= 10, `聚合搜索结果过少: ${search.items.length}`);
  assert((merged?.alternatives?.length ?? 0) >= 2, '跨源片名没有合并线路');

  const masterTarget = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';
  const masterResponse = await fetch(`${origin}/api/proxy?url=${encodeURIComponent(masterTarget)}`);
  const master = await masterResponse.text();
  assert(masterResponse.ok && master.startsWith('#EXTM3U'), 'Web 代理没有返回 HLS 主清单');
  const variant = master.split(/\r?\n/).find((line) => line.startsWith('/api/proxy?'));
  assert(variant && !master.includes('http://localhost'), 'HLS 子清单没有保持同源相对地址');

  const variantResponse = await fetch(`${origin}${variant}`);
  const playlist = await variantResponse.text();
  const segment = playlist.split(/\r?\n/).find((line) => line.startsWith('/api/proxy?'));
  assert(variantResponse.ok && segment, 'Web 代理没有递归重写媒体清单');
  const segmentResponse = await fetch(`${origin}${segment}`, { headers: { Range: 'bytes=0-65535' } });
  const bytes = (await segmentResponse.arrayBuffer()).byteLength;
  assert(segmentResponse.ok && bytes > 10_000, `Web 代理媒体数据不足: ${bytes}`);

  console.log(`Web smoke passed: ${search.items.length} grouped results, 2 merged sources, ${bytes} media bytes`);
} finally {
  child.kill('SIGTERM');
}
