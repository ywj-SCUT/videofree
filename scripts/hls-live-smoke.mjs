import assert from 'node:assert/strict';
import { connect } from 'node:net';
import { fetch as undiciFetch, ProxyAgent } from 'undici';
import { filterHlsManifest, inferredAdSegmentIndexes } from '../dist-electron/hls-filter.js';
import { selectPrefetchSegmentUrls } from '../dist-electron/prefetch-manager.js';

const defaultHeaders = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131 Safari/537.36',
  Accept: '*/*',
};

function proxyAvailable() {
  return new Promise((resolve) => {
    const socket = connect({ host: '127.0.0.1', port: 7890 });
    const finish = (available) => { socket.destroy(); resolve(available); };
    socket.setTimeout(500);
    socket.once('connect', () => finish(true));
    socket.once('timeout', () => finish(false));
    socket.once('error', () => finish(false));
  });
}

async function fetchText(url, headers = {}) {
  const request = async (dispatcher) => {
    const response = await undiciFetch(url, {
      headers: { ...defaultHeaders, ...headers },
      redirect: 'follow',
      dispatcher,
      signal: AbortSignal.timeout(15_000),
    });
    if (!response.ok) throw new Error(`${url}: HTTP ${response.status}`);
    return response.text();
  };
  try {
    return await request(undefined);
  } catch (directError) {
    if (!await proxyAvailable()) throw directError;
    const proxy = new ProxyAgent('http://127.0.0.1:7890');
    try {
      return await request(proxy);
    } finally {
      await proxy.close();
    }
  }
}

async function loadStrangerThings(source) {
  const search = JSON.parse(await fetchText(`${source.api}?ac=videolist&wd=${encodeURIComponent('怪奇物语第一季')}&pg=1`));
  const item = (search.list ?? []).find((entry) => String(entry.vod_name ?? '').includes('怪奇物语'));
  assert(item?.vod_id, `${source.name} 联网 CMS 搜索应返回《怪奇物语》`);
  const detail = JSON.parse(await fetchText(`${source.api}?ac=videolist&ids=${encodeURIComponent(item.vod_id)}`));
  const playValue = String(detail.list?.[0]?.vod_play_url ?? '');
  const discoveredUrl = playValue.match(/https?:\/\/[^#$\s]+?\.m3u8(?:\?[^#$\s]*)?/i)?.[0];
  const masterUrl = source.overrideUrl ?? discoveredUrl;
  assert(masterUrl, `${source.name} 真实详情应包含 HLS 播放地址`);
  const master = await fetchText(masterUrl, { Referer: new URL(masterUrl).origin });
  const nested = master.split(/\r?\n/).map((line) => line.trim()).find((line) => line && !line.startsWith('#'));
  if (!master.includes('#EXTINF')) assert(nested, `${source.name} 主清单应包含媒体子清单`);
  const mediaUrl = master.includes('#EXTINF') ? masterUrl : new URL(nested, masterUrl).toString();
  const media = master.includes('#EXTINF') ? master : await fetchText(mediaUrl, { Referer: masterUrl });
  return { source: source.name, title: item.vod_name, mediaUrl, media };
}

const sources = [
  { name: 'C', api: 'https://cj.lziapi.com/api.php/provide/vod/' },
  { name: 'F', api: 'https://cj.rycjapi.com/api.php/provide/vod/' },
  { name: 'G', api: 'https://cj.ffzyapi.com/api.php/provide/vod/', overrideUrl: process.env.VIDEOGET_HLS_LIVE_URL },
];
const playlists = [];
for (const source of sources) playlists.push(await loadStrangerThings(source));

const reports = playlists.map((playlist) => {
  const inferred = inferredAdSegmentIndexes(playlist.media);
  const filtered = filterHlsManifest(playlist.media);
  return {
    ...playlist,
    inferred,
    filtered,
    segments: (playlist.media.match(/^#EXTINF:/gm) ?? []).length,
  };
});
for (const report of reports.filter((entry) => entry.source === 'C' || entry.source === 'F')) {
  assert.equal(report.inferred.length, 0, `${report.source} 大量正常 discontinuity 分块不得被推断为广告`);
  assert.equal(report.filtered.removedSegments, 0, `${report.source} 真实清单不得误删`);
}
const target = reports.find((entry) => entry.source === 'G');
assert(target);
assert(target.inferred.length > 0, '真实 G 清单应识别出被长内容夹住的短岛');
assert.equal(target.filtered.removedSegments, target.inferred.length);
const proxiedMedia = target.filtered.manifest.replace(/^(?!#)(\S+)$/gm, (uri) => `http://127.0.0.1:19000/stream?url=${encodeURIComponent(new URL(uri, target.mediaUrl).toString())}`);
const selected = selectPrefetchSegmentUrls(proxiedMedia);
assert(selected.length > 6 && selected.length <= 24);

console.log(JSON.stringify({
  playlists: reports.map((report) => ({
    source: report.source,
    title: report.title,
    mediaUrl: report.mediaUrl,
    segments: report.segments,
    inferredAdSegments: report.inferred.length,
    removedDuration: Number(report.filtered.removedDuration.toFixed(3)),
  })),
  selectedPrefetchSegments: selected.length,
}, null, 2));
