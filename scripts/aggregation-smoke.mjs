import { DEFAULT_SOURCES } from '../dist-electron/default-sources.js';
import { aggregateSearch, inferMediaCategory, resolveMedia } from '../dist-electron/source-engine.js';

const categoryCases = [
  ['动作电影', 'movie'],
  ['国产剧', 'series'],
  ['日韩动漫', 'anime'],
  ['女频恋爱短剧', 'short'],
  ['AIGC AI短剧', 'ai-short'],
];
for (const [input, expected] of categoryCases) {
  const actual = inferMediaCategory(input);
  if (actual !== expected) throw new Error(`分类失败：${input} 应为 ${expected}，实际为 ${actual}`);
}

const search = await aggregateSearch(DEFAULT_SOURCES, '哪吒', 'all');
if (search.failures.length) throw new Error(`来源搜索失败：${JSON.stringify(search.failures)}`);
const shared = search.items.find((item) => (item.alternatives?.length ?? 0) >= 2);
if (!shared) throw new Error('没有找到可验证的跨来源同名结果');
const resolved = await resolveMedia(DEFAULT_SOURCES, shared);
if (!resolved) throw new Error('跨来源详情解析为空');
const lineSources = new Set((resolved.playLines ?? []).map((line) => line.name.split(' · ')[0]));
if (lineSources.size < 2) throw new Error(`跨来源线路不足：${[...lineSources].join(', ')}`);
const missingEpisodeSource = (resolved.playLines ?? []).some((line) =>
  line.episodes.some((episode) => !episode.sourceId));
if (missingEpisodeSource) throw new Error('跨来源线路存在缺失来源 ID 的剧集');

const aiShorts = await aggregateSearch([], '', 'ai-short');
if (!aiShorts.items.some((item) => item.category === 'ai-short')) throw new Error('AI 短剧分类没有可展示内容');

console.log(JSON.stringify({
  query: '哪吒',
  rawVariants: search.items.reduce((count, item) => count + (item.alternatives?.length ?? 1), 0),
  groupedItems: search.items.length,
  sharedTitle: shared.title,
  variants: shared.alternatives,
  mergedLines: resolved.playLines?.map((line) => line.name),
  categoryCases: categoryCases.map(([input, expected]) => ({ input, expected })),
  aiShortItems: aiShorts.items.length,
}, null, 2));
