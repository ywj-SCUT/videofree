import { importTvBox } from '../dist-electron/source-engine.js';

const spiderScript = `
module.exports.search = function (query) {
  return { url: 'https://example.com/search?q=' + encodeURIComponent(query) };
};
module.exports.parseSearch = function () { return []; };
`;

const imported = importTvBox({
  sites: [
    {
      key: 'fixture-cms',
      name: 'Fixture CMS',
      type: 1,
      api: 'https://example.com/api.php/provide/vod/',
      searchable: 1,
    },
    {
      key: 'fixture-spider',
      name: 'Fixture Spider',
      type: 3,
      ext: { script: spiderScript },
      searchable: 0,
    },
    { key: 'ignored-site', name: 'Ignored', type: 1, api: 'not-a-url' },
  ],
  lives: [
    {
      key: 'fixture-live',
      name: 'Fixture Live',
      url: 'https://example.com/live.m3u',
      channels: [
        { name: 'Fixture Channel', group: 'Tests', url: 'https://example.com/live.m3u8' },
      ],
    },
  ],
});

if (imported.sources.length !== 2) throw new Error(`点播源导入数量错误：${imported.sources.length}`);
const cms = imported.sources.find((source) => source.id === 'fixture-cms');
if (!cms || cms.type !== 'cms' || cms.api !== 'https://example.com/api.php/provide/vod/' || !cms.searchable) {
  throw new Error('CMS 源字段映射错误');
}
const spider = imported.sources.find((source) => source.id === 'fixture-spider');
if (!spider || spider.type !== 'spider' || spider.script !== spiderScript || spider.searchable) {
  throw new Error('Spider 源字段映射错误');
}
if (imported.livePlaylists.length !== 1 || imported.livePlaylists[0].url !== 'https://example.com/live.m3u') {
  throw new Error('TVBox 直播列表引用导入错误');
}
if (imported.lives.length !== 1 || imported.lives[0].url !== 'https://example.com/live.m3u8') {
  throw new Error('TVBox 内联直播频道导入错误');
}

console.log(JSON.stringify({
  sources: imported.sources.map(({ id, name, type, searchable }) => ({ id, name, type, searchable })),
  livePlaylists: imported.livePlaylists.length,
  inlineLiveChannels: imported.lives.length,
  ignoredInvalidSites: 1,
}, null, 2));
