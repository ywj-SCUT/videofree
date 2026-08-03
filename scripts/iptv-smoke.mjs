import { buildIptvCatalog, fetchIptvCatalog } from '../dist-electron/iptv-catalog.js';

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const fixture = buildIptvCatalog([
  { id: 'CCTV1.cn', name: 'CCTV-1', country: 'CN', categories: ['general'] },
  { id: 'Demo.tw', name: '台湾测试台', country: 'TW', categories: ['news'] },
  { id: 'Hidden.us', name: 'Excluded', country: 'US', categories: ['general'] },
], [
  { channel: 'CCTV1.cn', url: 'https://example.com/cctv-1.m3u8' },
  { channel: 'CCTV1.cn', url: 'https://backup.example.com/cctv-1.m3u8' },
  { channel: 'Demo.tw', url: 'https://example.com/tw.m3u8' },
  { channel: 'Hidden.us', url: 'https://example.com/us.m3u8' },
]);
assert(fixture.length === 2, `目录过滤结果异常: ${fixture.length}`);
assert(fixture.find((channel) => channel.tvgId === 'CCTV1.cn')?.urls?.length === 2, '同频道多线路没有合并');

const live = await fetchIptvCatalog();
assert(live.length >= 100, `公开 IPTV 目录频道过少: ${live.length}`);
assert(live.every((channel) => channel.sourceId === 'iptv-org' && channel.urls?.length), '公开 IPTV 频道字段不完整');

const regions = [...new Set(live.map((channel) => channel.group.split(' · ')[0]))];
console.log(JSON.stringify({ fixtureChannels: fixture.length, liveChannels: live.length, regions, sample: live.slice(0, 5).map((channel) => channel.name) }, null, 2));
