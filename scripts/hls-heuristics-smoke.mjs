import assert from 'node:assert/strict';
import { filterHlsManifest, inferredAdSegmentIndexes } from '../dist-electron/hls-filter.js';
import { orderFullEpisodePrefetchUrls, selectPrefetchSegmentUrls } from '../dist-electron/prefetch-manager.js';

function group(name, durations) {
  return durations.map((duration, index) => `#EXTINF:${duration},\nhttp://127.0.0.1:19000/stream?url=${name}-${index}.ts`).join('\n');
}

const long = (name, count = 24) => group(name, Array.from({ length: count }, () => 10));
const short = (name, count = 5, duration = 4) => group(name, Array.from({ length: count }, () => duration));
const manifest = (...groups) => `#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:0\n${groups.join('\n#EXT-X-DISCONTINUITY\n')}\n#EXT-X-ENDLIST`;

const strangerThingsShape = manifest(
  long('content-a'),
  short('ad-a'),
  long('content-b', 30),
  short('ad-b', 4, 4.4),
  long('content-c', 28),
  short('ad-c'),
  long('content-d', 22),
);
const inferred = inferredAdSegmentIndexes(strangerThingsShape);
assert.equal(inferred.length, 14, '三个长内容组之间的短岛应被识别');
const filtered = filterHlsManifest(strangerThingsShape);
assert.equal(filtered.removedSegments, 14);
assert(!filtered.manifest.includes('ad-a') && !filtered.manifest.includes('ad-b') && !filtered.manifest.includes('ad-c'));
assert(filtered.manifest.includes('content-a') && filtered.manifest.includes('content-d'));

const explicitMarkers = filterHlsManifest(`#EXTM3U
#EXT-X-CUE-OUT:8
#EXTINF:4,
ads/mid-1.ts
#EXTINF:4,
ads/mid-2.ts
#EXT-X-CUE-IN
#EXTINF:4,
main/content.ts`);
assert.equal(explicitMarkers.removedSegments, 2, '显式 CUE/URI 广告标记仍应优先生效');
assert(explicitMarkers.manifest.includes('main/content.ts'));

const repeatedBoundary = filterHlsManifest(manifest(
  short('boundary-ad'),
  long('boundary-content-a'),
  short('middle-ad'),
  long('boundary-content-b'),
));
assert.equal(repeatedBoundary.removedSegments, 10, '边界短岛仅在存在近似重复岛时删除');
assert.equal(filterHlsManifest(manifest(short('unique-opening', 6, 5), long('feature'))).removedSegments, 0);

const normalDiscontinuities = manifest(...Array.from({ length: 120 }, (_, index) => (
  index % 3 === 0 ? short(`normal-${index}`, 5, 4) : short(`normal-${index}`, 10, 4)
)));
assert.equal(inferredAdSegmentIndexes(normalDiscontinuities).length, 0, '无 180 秒长组时不得删除正常 discontinuity 分块');
assert.equal(filterHlsManifest(normalDiscontinuities).removedSegments, 0);

const timedManifest = manifest(group('timeline', Array.from({ length: 42 }, () => 60)));
const selected = selectPrefetchSegmentUrls(timedManifest);
const selectedIndexes = selected.map((url) => Number(url.match(/timeline-(\d+)\.ts/)?.[1]));
assert.deepEqual(selectedIndexes.slice(0, 8), [0, 1, 2, 3, 4, 5, 6, 10]);
assert(selectedIndexes.includes(40) && selectedIndexes.includes(41), '应选择每 5 分钟锚点所在分片及后一片');
assert(selected.length <= 24);
const fullEpisode = orderFullEpisodePrefetchUrls(timedManifest);
assert.equal(fullEpisode.length, 42);
assert.equal(new Set(fullEpisode).size, 42);
assert(fullEpisode.indexOf('http://127.0.0.1:19000/stream?url=timeline-40.ts') < fullEpisode.indexOf('http://127.0.0.1:19000/stream?url=timeline-7.ts'));

console.log(JSON.stringify({
  inferredAds: inferred.length,
  normalDiscontinuityGroups: 120,
  selectedPrefetchSegments: selected.length,
  fullEpisodePrefetchSegments: fullEpisode.length,
  lastSelectedIndex: selectedIndexes.at(-1),
}, null, 2));
