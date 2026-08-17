export interface HlsFilterResult {
  manifest: string;
  removedSegments: number;
  removedDuration: number;
  removedMarkers: number;
}

interface SegmentBlock {
  tags: string[];
  uri: string;
  duration: number;
}

type PlaylistEntry = { raw: string } | { segment: SegmentBlock };

interface SegmentGroup {
  segmentIndexes: number[];
  duration: number;
  count: number;
}

const segmentTag = /^(#EXTINF|#EXT-X-(?:BYTERANGE|KEY|MAP|DISCONTINUITY|PROGRAM-DATE-TIME|DATERANGE|CUE-|SCTE35|ASSET)|#EXT-OATCLS-SCTE35)/i;
const markerTag = /^(#EXT-X-(?:CUE-|SCTE35|ASSET)|#EXT-OATCLS-SCTE35)/i;
const longContentDuration = 180;
const shortIslandMinDuration = 5;
const shortIslandMaxDuration = 90;
const shortIslandMaxSegments = 20;

function durationFromExtinf(line: string): number {
  const matched = line.match(/^#EXTINF:([\d.]+)/i);
  return matched ? Number(matched[1]) : 0;
}

function adUri(uri: string): boolean {
  try {
    const parsed = new URL(uri, 'https://fixture.invalid');
    return /(?:^|[./_-])(?:ads?|advert|adserver|commercial|preroll|midroll|postroll)(?:[./_-]|$)/i.test(`${parsed.hostname}${parsed.pathname}`);
  } catch {
    return false;
  }
}

function adDateRange(line: string): { ad: boolean; external: boolean; duration: number } {
  if (!/^#EXT-X-DATERANGE:/i.test(line)) return { ad: false, external: false, duration: 0 };
  const ad = /(?:CLASS|ID)="[^"]*(?:interstitial|advert|commercial|\bad\b)[^"]*"/i.test(line) || /SCTE35-OUT=/i.test(line);
  const external = /X-ASSET-(?:URI|LIST)=/i.test(line);
  const duration = Number(line.match(/(?:PLANNED-)?DURATION=([\d.]+)/i)?.[1] ?? 0);
  return { ad, external, duration: Number.isFinite(duration) ? duration : 0 };
}

function parseEntries(manifest: string): PlaylistEntry[] {
  const entries: PlaylistEntry[] = [];
  let tags: string[] = [];
  let duration = 0;
  for (const line of manifest.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (/^#EXTINF:/i.test(trimmed)) {
      tags.push(line);
      duration = durationFromExtinf(trimmed);
      continue;
    }
    if (tags.length && !trimmed.startsWith('#') && trimmed) {
      entries.push({ segment: { tags, uri: line, duration } });
      tags = [];
      duration = 0;
      continue;
    }
    if (segmentTag.test(trimmed)) {
      tags.push(line);
      continue;
    }
    if (tags.length) {
      entries.push(...tags.map((raw) => ({ raw })));
      tags = [];
      duration = 0;
    }
    entries.push({ raw: line });
  }
  entries.push(...tags.map((raw) => ({ raw })));
  return entries;
}

function segmentGroups(entries: PlaylistEntry[]): SegmentGroup[] {
  const groups: SegmentGroup[] = [];
  let current: SegmentGroup | null = null;
  let segmentIndex = 0;
  for (const entry of entries) {
    if ('raw' in entry) continue;
    const discontinuity = entry.segment.tags.some((tag) => /^#EXT-X-DISCONTINUITY\s*$/i.test(tag.trim()));
    if (!current || (discontinuity && current.count > 0)) {
      current = { segmentIndexes: [], duration: 0, count: 0 };
      groups.push(current);
    }
    current.segmentIndexes.push(segmentIndex++);
    current.duration += entry.segment.duration;
    current.count++;
  }
  return groups;
}

function isLongContent(group: SegmentGroup | undefined): boolean {
  return Boolean(group && group.duration >= longContentDuration);
}

function isShortIsland(group: SegmentGroup): boolean {
  return group.duration >= shortIslandMinDuration
    && group.duration <= shortIslandMaxDuration
    && group.count <= shortIslandMaxSegments;
}

function similarIsland(left: SegmentGroup, right: SegmentGroup): boolean {
  const durationTolerance = Math.max(2, Math.max(left.duration, right.duration) * 0.15);
  return Math.abs(left.duration - right.duration) <= durationTolerance
    && Math.abs(left.count - right.count) <= 1;
}

export function inferredAdSegmentIndexes(manifest: string): number[] {
  const groups = segmentGroups(parseEntries(manifest));
  if (!groups.some(isLongContent)) return [];

  const candidates = groups
    .map((group, index) => ({ group, index }))
    .filter(({ group }) => isShortIsland(group));
  const dropGroups = new Set<number>();

  for (const { group, index } of candidates) {
    const previousLong = isLongContent(groups[index - 1]);
    const nextLong = isLongContent(groups[index + 1]);
    if (previousLong && nextLong) {
      dropGroups.add(index);
      continue;
    }
    const boundary = index === 0 || index === groups.length - 1;
    if (!boundary || (!previousLong && !nextLong)) continue;
    const repeated = candidates.some(({ group: other, index: otherIndex }) => {
      if (otherIndex === index) return false;
      const otherAdjacentToLong = isLongContent(groups[otherIndex - 1]) || isLongContent(groups[otherIndex + 1]);
      return otherAdjacentToLong && similarIsland(group, other);
    });
    if (repeated) dropGroups.add(index);
  }

  return groups.flatMap((group, index) => dropGroups.has(index) ? group.segmentIndexes : []);
}

export function filterHlsManifest(manifest: string): HlsFilterResult {
  const entries = parseEntries(manifest);
  const inferredAds = new Set(inferredAdSegmentIndexes(manifest));
  const output: PlaylistEntry[] = [];
  let inCue = false;
  let timedAdRemaining = 0;
  let removedSegments = 0;
  let removedDuration = 0;
  let removedMarkers = 0;
  let removedBeforeFirstKept = 0;
  let keptSegments = 0;
  let needsDiscontinuity = false;
  let activeKey: string | null = null;
  let activeMap: string | null = null;
  let emittedKey: string | null = null;
  let emittedMap: string | null = null;
  let segmentIndex = 0;

  for (const entry of entries) {
    if ('raw' in entry) {
      const range = adDateRange(entry.raw.trim());
      if (range.ad) {
        removedMarkers++;
        if (!range.external && range.duration > 0) timedAdRemaining = Math.max(timedAdRemaining, range.duration);
        continue;
      }
      output.push(entry);
      continue;
    }
    const block = entry.segment;
    const inferredAd = inferredAds.has(segmentIndex++);
    for (const tag of block.tags) {
      const trimmed = tag.trim();
      if (/^#EXT-X-KEY:/i.test(trimmed)) activeKey = tag;
      if (/^#EXT-X-MAP:/i.test(trimmed)) activeMap = tag;
    }
    const hasCueIn = block.tags.some((tag) => /^#EXT-X-CUE-IN/i.test(tag.trim()));
    const hasCueOut = block.tags.some((tag) => /^#EXT-X-CUE-OUT/i.test(tag.trim()));
    if (hasCueIn) inCue = false;
    if (hasCueOut) inCue = true;
    for (const tag of block.tags) {
      const range = adDateRange(tag.trim());
      if (range.ad) {
        removedMarkers++;
        if (!range.external && range.duration > 0) timedAdRemaining = Math.max(timedAdRemaining, range.duration);
      }
      if (markerTag.test(tag.trim())) removedMarkers++;
    }
    const drop = inferredAd || inCue || timedAdRemaining > 0 || adUri(block.uri.trim());
    if (drop) {
      removedSegments++;
      removedDuration += block.duration;
      if (!keptSegments) removedBeforeFirstKept++;
      timedAdRemaining = Math.max(0, timedAdRemaining - block.duration);
      needsDiscontinuity = keptSegments > 0;
      continue;
    }
    const tags = block.tags.filter((tag) => !markerTag.test(tag.trim()) && !adDateRange(tag.trim()).ad);
    const hasKey = tags.some((tag) => /^#EXT-X-KEY:/i.test(tag.trim()));
    const hasMap = tags.some((tag) => /^#EXT-X-MAP:/i.test(tag.trim()));
    const restoredState: string[] = [];
    if (!hasKey && activeKey && activeKey !== emittedKey) restoredState.push(activeKey);
    if (!hasMap && activeMap && activeMap !== emittedMap) restoredState.push(activeMap);
    tags.unshift(...restoredState);
    if (needsDiscontinuity && !tags.some((tag) => /^#EXT-X-DISCONTINUITY/i.test(tag.trim()))) tags.unshift('#EXT-X-DISCONTINUITY');
    output.push({ segment: { ...block, tags } });
    for (const tag of tags) {
      const trimmed = tag.trim();
      if (/^#EXT-X-KEY:/i.test(trimmed)) emittedKey = tag;
      if (/^#EXT-X-MAP:/i.test(trimmed)) emittedMap = tag;
    }
    keptSegments++;
    needsDiscontinuity = false;
  }

  const lines = output.flatMap((entry) => 'raw' in entry ? [entry.raw] : [...entry.segment.tags, entry.segment.uri]);
  if (removedBeforeFirstKept) {
    const index = lines.findIndex((line) => /^#EXT-X-MEDIA-SEQUENCE:/i.test(line.trim()));
    if (index >= 0) lines[index] = lines[index].replace(/(MEDIA-SEQUENCE:)(\d+)/i, (_match, prefix, value) => `${prefix}${Number(value) + removedBeforeFirstKept}`);
  }
  return { manifest: lines.join('\n'), removedSegments, removedDuration, removedMarkers };
}
