import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { aggregateDanmaku, mergeDanmakuComments, parseDanmakuXml } from '../dist-electron/danmaku-engine.js';

const parsed = parseDanmakuXml('<?xml version="1.0"?><i><d p="1.25,1,25,16777215">同一条弹幕</d><d p="1.25,1,25,16777215">同一条弹幕</d><d p="2.5,5,25,65280">顶部弹幕</d></i>', 'fixture-xml');
assert.equal(parsed.length, 3);
assert.equal(parsed[1].color, '#ffffff');
assert.equal(parsed[2].mode, 1);
assert.equal(mergeDanmakuComments([parsed]).length, 2);

const server = createServer((request, response) => {
  response.setHeader('Content-Type', 'application/json; charset=utf-8');
  if (request.url === '/api/v2/search/episodes') {
    response.end(JSON.stringify({ animes: [{ animeTitle: '凡人修仙传', episodes: [{ episodeId: 9001, episodeTitle: '第 1 集' }] }] }));
    return;
  }
  if (request.url?.startsWith('/api/v2/comment/9001')) {
    response.end(JSON.stringify({ comments: [
      { p: '3.5,1,16777215,0', m: 'VideoGET 多源聚合样本' },
      { p: '3.5,1,16777215,0', m: 'VideoGET 多源聚合样本' },
    ] }));
    return;
  }
  response.statusCode = 404;
  response.end(JSON.stringify({ error: 'not found' }));
});

await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const address = server.address();
assert(address && typeof address === 'object');

try {
  const result = await aggregateDanmaku([
    { id: 'bilibili', name: 'Bilibili 弹幕', type: 'bilibili', enabled: true },
    { id: 'fixture', name: '兼容源样本', type: 'dandanplay', api: `http://127.0.0.1:${address.port}`, enabled: true },
  ], '凡人修仙传', '第 1 集');
  assert(result.comments.length > 100, '真实弹幕数量应超过 100');
  assert(result.matches.some((match) => match.providerId === 'bilibili'), '应匹配 Bilibili 番剧');
  assert(result.matches.some((match) => match.providerId === 'fixture'), '应合并兼容提供方');
  assert.equal(result.comments.filter((comment) => comment.text === 'VideoGET 多源聚合样本').length, 1, '重复弹幕应去重');
  assert.equal(result.failures.length, 0);
  const episodeTwo = await aggregateDanmaku([
    { id: 'bilibili', name: 'Bilibili 弹幕', type: 'bilibili', enabled: true },
  ], '凡人修仙传', '第02集');
  assert(episodeTwo.comments.length > 100, '第二集应返回真实弹幕');
  assert(episodeTwo.matches.some((match) => /^2(?:\s|$)/.test(match.episode)), '带前导零的集数应匹配第二集');
  console.log(JSON.stringify({
    comments: result.comments.length,
    providers: result.matches.map((match) => `${match.providerName}: ${match.count}`),
    elapsedMs: result.elapsedMs,
    fixtureDeduplicated: true,
    episodeTwo: { comments: episodeTwo.comments.length, match: episodeTwo.matches[0]?.episode },
  }, null, 2));
} finally {
  await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
}
