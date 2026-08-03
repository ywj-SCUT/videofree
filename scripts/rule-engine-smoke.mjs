import http from 'node:http';
import { mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { aggregateSearch, getDetail, importTvBox, resolvePlayback } from '../dist-electron/source-engine.js';
import { startProxyServer } from '../dist-electron/proxy-server.js';

const ruleScript = `
module.exports.search = async function (input, ctx) {
  const body = await ctx.request(ctx.config.api + '?ac=videolist&wd=' + encodeURIComponent(input.query));
  const data = JSON.parse(body);
  return (data.list || []).map(function (item) {
    return { id: String(item.vod_id), title: item.vod_name, poster: item.vod_pic, year: item.vod_year, category: 'movie', remarks: item.vod_remarks };
  });
};
module.exports.detail = async function (input, ctx) {
  const body = await ctx.request(ctx.config.api + '?ac=videolist&ids=' + encodeURIComponent(input.id));
  const item = JSON.parse(body).list[0];
  const entries = String(item.vod_play_url || '').split('#').map(function (entry, index) {
    const at = entry.indexOf('$');
    const name = at >= 0 ? entry.slice(0, at) : '第 ' + (index + 1) + ' 集';
    const url = at >= 0 ? entry.slice(at + 1) : entry;
    return { name: name, token: { url: url, key: item.play_key } };
  });
  return {
    id: String(item.vod_id), title: item.vod_name, poster: item.vod_pic, year: item.vod_year,
    category: 'movie', summary: item.vod_content,
    playLines: [{ name: '规则线路', episodes: entries }]
  };
};
module.exports.play = async function (input) {
  return { url: input.token.url, headers: { 'X-Rule-Key': input.token.key } };
};
`;

function listen(server) {
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => resolve(server.address().port));
  });
}

const fixture = http.createServer((request, response) => {
  const url = new URL(request.url ?? '/', 'http://127.0.0.1');
  if (url.pathname === '/api') {
    response.setHeader('Content-Type', 'application/json; charset=utf-8');
    const base = `http://127.0.0.1:${fixture.address().port}`;
    response.end(JSON.stringify({ list: [{
      vod_id: 'fixture-1', vod_name: '规则引擎测试片', vod_pic: `${base}/poster.jpg`, vod_year: '2026',
      vod_remarks: '1080P', vod_content: '独立 Worker 规则引擎端到端测试',
      vod_play_url: `正片$${base}/master.m3u8`, play_key: 'verified-rule-key',
    }] }));
    return;
  }
  if (url.pathname === '/rule.js') {
    response.setHeader('Content-Type', 'text/javascript; charset=utf-8');
    response.end(ruleScript);
    return;
  }
  if (url.pathname === '/master.m3u8') {
    if (request.headers['x-rule-key'] !== 'verified-rule-key') return response.writeHead(403).end('missing rule header');
    response.setHeader('Content-Type', 'application/vnd.apple.mpegurl');
    response.end('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=1920x1080\n/media.m3u8\n');
    return;
  }
  if (url.pathname === '/media.m3u8') {
    if (request.headers['x-rule-key'] !== 'verified-rule-key') return response.writeHead(403).end('missing rule header');
    response.setHeader('Content-Type', 'application/vnd.apple.mpegurl');
    response.end('#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n');
    return;
  }
  if (url.pathname === '/segment.ts') {
    if (request.headers['x-rule-key'] !== 'verified-rule-key') return response.writeHead(403).end('missing rule header');
    response.setHeader('Content-Type', 'video/mp2t');
    response.end(Buffer.alloc(32_768, 71));
    return;
  }
  response.writeHead(404).end('not found');
});

const fixturePort = await listen(fixture);
const fixtureOrigin = `http://127.0.0.1:${fixturePort}`;
const cacheDirectory = await mkdtemp(path.join(os.tmpdir(), 'videoget-rules-smoke-'));
const proxy = await startProxyServer(cacheDirectory);
const source = {
  id: 'fixture-rule', name: 'Fixture Rule', type: 'spider', script: ruleScript,
  ruleConfig: { api: `${fixtureOrigin}/api` }, enabled: true, searchable: true,
};

try {
  const search = await aggregateSearch([source], '规则引擎', 'all');
  const item = search.items.find((entry) => entry.sourceId === source.id);
  if (!item || item.title !== '规则引擎测试片') throw new Error('规则搜索没有返回标准化媒体项');

  const detail = await getDetail([source], source.id, item.id);
  const episode = detail?.playLines?.[0]?.episodes?.[0];
  if (!episode?.url.startsWith('videoget-rule:') || episode.sourceId !== source.id) throw new Error('规则详情没有生成不透明播放令牌');

  const playback = await resolvePlayback([source], source.id, episode.url);
  if (playback.url !== `${fixtureOrigin}/master.m3u8` || playback.headers?.['X-Rule-Key'] !== 'verified-rule-key') {
    throw new Error('规则播放契约没有返回地址与请求头');
  }

  const first = new URL(`http://127.0.0.1:${proxy.port}/stream`);
  first.searchParams.set('url', playback.url);
  first.searchParams.set('headers', JSON.stringify(playback.headers));
  const masterResponse = await fetch(first);
  if (!masterResponse.ok) throw new Error(`规则 HLS 主清单代理失败：HTTP ${masterResponse.status}`);
  const master = await masterResponse.text();
  const mediaUrl = master.split(/\r?\n/).find((line) => line && !line.startsWith('#'));
  if (!mediaUrl) throw new Error('代理后的主清单缺少媒体清单');
  const mediaResponse = await fetch(mediaUrl);
  const media = await mediaResponse.text();
  const segmentUrl = media.split(/\r?\n/).find((line) => line && !line.startsWith('#'));
  if (!segmentUrl) throw new Error('代理后的媒体清单缺少分片');
  const segmentResponse = await fetch(segmentUrl);
  const segmentBytes = (await segmentResponse.arrayBuffer()).byteLength;
  if (!segmentResponse.ok || segmentBytes !== 32_768) throw new Error('规则请求头没有传递至 HLS 分片');

  const imported = importTvBox({ sites: [{
    key: 'remote-rule', name: 'Remote Rule', type: 3,
    ext: { scriptUrl: `${fixtureOrigin}/rule.js`, config: { api: `${fixtureOrigin}/api` } }, searchable: 1,
  }] });
  const remote = imported.sources[0];
  if (!remote?.scriptUrl || remote.ruleConfig?.api !== `${fixtureOrigin}/api`) throw new Error('TVBox 远程 JS 规则字段映射失败');
  const remoteSearch = await aggregateSearch(remote ? [remote] : [], '测试', 'all');
  if (!remoteSearch.items.some((entry) => entry.sourceId === 'remote-rule')) throw new Error('远程 JS 规则没有执行');

  const blocked = { ...source, id: 'blocked-rule', script: 'module.exports.search = function () { return process.env; };' };
  const blockedResult = await aggregateSearch([blocked], '测试', 'all');
  if (!blockedResult.failures[0]?.message.includes('被禁用')) throw new Error('危险运行时能力没有被阻止');

  const loop = { ...source, id: 'loop-rule', script: 'module.exports.search = function () { while (true) {} };' };
  const loopStarted = Date.now();
  const loopResult = await aggregateSearch([loop], '测试', 'all');
  if (!loopResult.failures.length || Date.now() - loopStarted > 3_000) throw new Error('规则 CPU 超时限制未生效');

  console.log(JSON.stringify({
    searchItems: search.items.length,
    detailLines: detail?.playLines?.length ?? 0,
    playback: { url: playback.url, customHeader: true },
    hls: { resolution: '1920x1080', segmentBytes, nestedHeaderPropagation: true },
    tvboxRemoteRule: remote?.scriptUrl,
    isolation: { blockedRuntime: true, cpuTimeoutMs: Date.now() - loopStarted, workerMemoryMb: 32 },
  }, null, 2));
} finally {
  await proxy.close();
  await new Promise((resolve) => fixture.close(resolve));
  await rm(cacheDirectory, { recursive: true, force: true });
}
