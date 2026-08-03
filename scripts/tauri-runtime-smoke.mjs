import assert from 'node:assert/strict';
import http from 'node:http';

const runtimeOrigin = process.env.TAURI_RUNTIME_ORIGIN ?? 'http://127.0.0.1:43127';
const ruleScript = `
module.exports.search = async function (input, ctx) {
  const body = await ctx.request(ctx.config.api + '?query=' + encodeURIComponent(input.query));
  return JSON.parse(body).list.map(function (item) {
    return { id: item.id, title: item.title, poster: item.poster, year: '2026', category: 'movie', remarks: '1080P' };
  });
};
module.exports.detail = async function (input, ctx) {
  const body = await ctx.request(ctx.config.api + '?id=' + encodeURIComponent(input.id));
  const item = JSON.parse(body).list[0];
  return {
    id: item.id, title: item.title, poster: item.poster, year: '2026', category: 'movie',
    playLines: [{ name: 'Rule Line', episodes: [{ name: 'Main', token: { url: item.url, key: item.key } }] }]
  };
};
module.exports.play = async function (input) {
  return { url: input.token.url, headers: { 'X-Rule-Key': input.token.key } };
};`;

const fixture = http.createServer((request, response) => {
  const origin = `http://127.0.0.1:${fixture.address().port}`;
  if (request.url?.startsWith('/api')) {
    response.setHeader('Content-Type', 'application/json');
    response.end(JSON.stringify({ list: [{
      id: 'packaged-rule-1', title: 'Packaged Rule Fixture', poster: `${origin}/poster.jpg`,
      url: `${origin}/master.m3u8`, key: 'packaged-rule-key',
    }] }));
    return;
  }
  if (request.url === '/master.m3u8') {
    response.setHeader('Content-Type', 'application/vnd.apple.mpegurl');
    response.end('#EXTM3U\n#EXT-X-ENDLIST\n');
    return;
  }
  response.writeHead(404).end();
});

async function post(path, body) {
  const response = await fetch(`${runtimeOrigin}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  const payload = await response.json();
  assert(response.ok, `${path} returned HTTP ${response.status}: ${JSON.stringify(payload)}`);
  return payload;
}

await new Promise((resolve, reject) => {
  fixture.once('error', reject);
  fixture.listen(0, '127.0.0.1', resolve);
});

try {
  const root = await fetch(runtimeOrigin);
  assert.equal(root.status, 200, 'packaged Next service must be reachable');

  const fixtureOrigin = `http://127.0.0.1:${fixture.address().port}`;
  const source = {
    id: 'packaged-rule', name: 'Packaged Rule', type: 'spider', script: ruleScript,
    ruleConfig: { api: `${fixtureOrigin}/api` }, enabled: true, searchable: true,
  };
  const search = await post('/api/search', { query: 'fixture', category: 'all', sources: [source] });
  const item = search.items.find((entry) => entry.sourceId === source.id);
  assert(item, `packaged rule search failed: ${JSON.stringify(search)}`);
  assert.equal(item.title, 'Packaged Rule Fixture');

  const detail = await post('/api/detail', { sourceId: source.id, id: item.id, sources: [source] });
  const episode = detail?.playLines?.[0]?.episodes?.[0];
  assert(episode?.url.startsWith('videoget-rule:'), 'detail must return an opaque rule token');

  const playback = await post('/api/play', { sourceId: source.id, token: episode.url, sources: [source] });
  assert.equal(playback.url, `${fixtureOrigin}/master.m3u8`);
  assert.equal(playback.headers?.['X-Rule-Key'], 'packaged-rule-key');

  console.log(JSON.stringify({
    runtimeOrigin,
    rootStatus: root.status,
    searchItems: search.items.length,
    detailLines: detail.playLines.length,
    opaqueToken: true,
    customPlaybackHeader: true,
  }, null, 2));
} finally {
  fixture.closeAllConnections();
  await new Promise((resolve) => fixture.close(resolve));
}
