import type { PlayLine } from './types.js';

const SAMPLE_BYTES = 256 * 1024;
const MAX_PROBE_LINES = 8;

export interface RouteCandidate {
  index: number;
  name: string;
  url: string;
  headers?: Record<string, string>;
}

export interface RouteMetrics {
  ok: boolean;
  latencyMs: number;
  width: number;
  height: number;
  bandwidthMbps: number;
  throughputMbps: number;
}

interface RouteHealth {
  attempts: number;
  successes: number;
  consecutiveFailures: number;
  ewmaLatencyMs: number;
  ewmaThroughputMbps: number;
  cooldownUntil: number;
}

interface RankOptions {
  proxyPort: number;
  adFiltering: boolean;
  budgetMs?: number;
}

const healthByOrigin = new Map<string, RouteHealth>();

function originalUrl(value: string): string {
  try {
    const parsed = new URL(value);
    if ((parsed.hostname === '127.0.0.1' || parsed.hostname === 'localhost') && parsed.pathname === '/stream') {
      return parsed.searchParams.get('url') ?? value;
    }
  } catch {}
  return value;
}

function routeKey(value: string): string {
  try {
    return new URL(originalUrl(value)).origin;
  } catch {
    return value;
  }
}

function updateHealth(url: string, ok: boolean, latencyMs = 0, throughputMbps = 0): RouteHealth {
  const key = routeKey(url);
  const previous = healthByOrigin.get(key) ?? {
    attempts: 0,
    successes: 0,
    consecutiveFailures: 0,
    ewmaLatencyMs: 0,
    ewmaThroughputMbps: 0,
    cooldownUntil: 0,
  };
  const alpha = 0.3;
  const next: RouteHealth = {
    attempts: previous.attempts + 1,
    successes: previous.successes + (ok ? 1 : 0),
    consecutiveFailures: ok ? 0 : previous.consecutiveFailures + 1,
    ewmaLatencyMs: latencyMs > 0
      ? previous.ewmaLatencyMs > 0 ? previous.ewmaLatencyMs * (1 - alpha) + latencyMs * alpha : latencyMs
      : previous.ewmaLatencyMs,
    ewmaThroughputMbps: throughputMbps > 0
      ? previous.ewmaThroughputMbps > 0 ? previous.ewmaThroughputMbps * (1 - alpha) + throughputMbps * alpha : throughputMbps
      : previous.ewmaThroughputMbps,
    cooldownUntil: !ok && previous.consecutiveFailures >= 1 ? Date.now() + 2 * 60_000 : ok ? 0 : previous.cooldownUntil,
  };
  healthByOrigin.set(key, next);
  return next;
}

export function reportRouteOutcome(url: string, ok: boolean): void {
  if (/^https?:\/\//i.test(url)) updateHealth(url, ok);
}

function estimatedRequiredMbps(metrics: RouteMetrics): number {
  if (metrics.bandwidthMbps > 0) return metrics.bandwidthMbps;
  if (metrics.height >= 1080) return 3;
  if (metrics.height >= 900) return 2.6;
  if (metrics.height >= 720) return 1.8;
  if (metrics.height >= 600) return 1.4;
  return 1.1;
}

export function scoreRouteMetrics(metrics: RouteMetrics, health?: Partial<RouteHealth>): number {
  if (!metrics.ok) return -1_000 - (health?.consecutiveFailures ?? 0) * 120;
  const successRate = health?.attempts ? (health.successes ?? 0) / health.attempts : 0.8;
  const effectiveLatency = health?.ewmaLatencyMs || metrics.latencyMs;
  const effectiveThroughput = health?.ewmaThroughputMbps || metrics.throughputMbps;
  const qualityHeight = Math.min(1080, Math.max(0, metrics.height));
  const qualityTier = metrics.height >= 1080 ? 120 : metrics.height >= 720 ? 85 : metrics.height >= 600 ? 55 : 0;
  const requiredMbps = estimatedRequiredMbps(metrics);
  const reserveRatio = requiredMbps > 0 ? effectiveThroughput / requiredMbps : 0;
  const reserveScore = reserveRatio >= 1.5 ? 260
    : reserveRatio >= 1.2 ? 190
      : reserveRatio >= 1 ? 90
        : -Math.min(260, (1 - reserveRatio) * 360);
  const cooldownPenalty = (health?.cooldownUntil ?? 0) > Date.now() ? 420 : 0;
  return successRate * 420
    + qualityHeight / 1080 * 260
    + qualityTier
    + reserveScore
    + Math.min(100, effectiveThroughput * 20)
    - Math.min(320, effectiveLatency * 0.08)
    - (health?.consecutiveFailures ?? 0) * 100
    - cooldownPenalty;
}

export function rankRouteMetrics(entries: Array<{ index: number; metrics: RouteMetrics; health?: Partial<RouteHealth> }>): number[] {
  return [...entries]
    .sort((left, right) => scoreRouteMetrics(right.metrics, right.health) - scoreRouteMetrics(left.metrics, left.health))
    .map((entry) => entry.index);
}

function playbackProxyUrl(candidate: RouteCandidate, options: RankOptions): string {
  if (!options.proxyPort) return candidate.url;
  const params = new URLSearchParams({ url: candidate.url });
  if (options.adFiltering) params.set('filterAds', '1');
  if (candidate.headers && Object.keys(candidate.headers).length) params.set('headers', JSON.stringify(candidate.headers));
  return `http://127.0.0.1:${options.proxyPort}/stream?${params}`;
}

function attributeNumber(line: string, name: string): number {
  const match = new RegExp(`${name}=(?:\"([^\"]+)\"|([^,]+))`, 'i').exec(line);
  return Number(match?.[1] ?? match?.[2] ?? 0) || 0;
}

function streamVariants(manifest: string): Array<{ url: string; width: number; height: number; bandwidthMbps: number }> {
  const lines = manifest.split(/\r?\n/).map((line) => line.trim());
  const variants: Array<{ url: string; width: number; height: number; bandwidthMbps: number }> = [];
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index];
    if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
    const resolution = /RESOLUTION=(\d+)x(\d+)/i.exec(line);
    const url = lines.slice(index + 1).find((entry) => entry && !entry.startsWith('#'));
    if (!url) continue;
    variants.push({
      url,
      width: Number(resolution?.[1] ?? 0),
      height: Number(resolution?.[2] ?? 0),
      bandwidthMbps: attributeNumber(line, 'BANDWIDTH') / 1_000_000,
    });
  }
  return variants;
}

function bestVariant(variants: ReturnType<typeof streamVariants>): ReturnType<typeof streamVariants>[number] | null {
  if (!variants.length) return null;
  const preferred = variants.filter((variant) => variant.height > 0 && variant.height <= 1080);
  const pool = preferred.length ? preferred : variants;
  return [...pool].sort((left, right) => right.height - left.height || right.bandwidthMbps - left.bandwidthMbps)[0];
}

function firstMediaUrl(manifest: string): string | null {
  return manifest.split(/\r?\n/).map((line) => line.trim())
    .find((line) => line && !line.startsWith('#')) ?? null;
}

async function fetchWithSignal(url: string, init: RequestInit, parentSignal: AbortSignal, timeoutMs: number): Promise<Response> {
  const timeoutController = new AbortController();
  const timeout = setTimeout(() => timeoutController.abort(), timeoutMs);
  try {
    return await fetch(url, { ...init, signal: AbortSignal.any([parentSignal, timeoutController.signal]) });
  } finally {
    clearTimeout(timeout);
  }
}

async function sampleResponse(response: Response): Promise<{ bytes: number; elapsedMs: number }> {
  if (!response.body) return { bytes: 0, elapsedMs: 0 };
  const reader = response.body.getReader();
  const started = performance.now();
  let bytes = 0;
  try {
    while (bytes < SAMPLE_BYTES) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
    }
  } finally {
    await reader.cancel().catch(() => undefined);
  }
  return { bytes, elapsedMs: Math.max(1, performance.now() - started) };
}

async function probeCandidate(candidate: RouteCandidate, options: RankOptions, signal: AbortSignal): Promise<RouteMetrics> {
  const started = performance.now();
  let width = 0;
  let height = 0;
  let bandwidthMbps = 0;
  let target = playbackProxyUrl(candidate, options);
  const requestHeaders = options.proxyPort ? undefined : candidate.headers;
  const first = await fetchWithSignal(target, { headers: requestHeaders }, signal, 2_200);
  if (!first.ok && first.status !== 206) throw new Error(`HTTP ${first.status}`);
  const contentType = first.headers.get('content-type') ?? '';
  const isManifest = /mpegurl|m3u8/i.test(contentType) || originalUrl(target).toLowerCase().includes('.m3u8');
  if (isManifest) {
    let manifest = await first.text();
    const variant = bestVariant(streamVariants(manifest));
    if (variant) {
      width = variant.width;
      height = variant.height;
      bandwidthMbps = variant.bandwidthMbps;
      target = new URL(variant.url, first.url).toString();
      const nested = await fetchWithSignal(target, { headers: requestHeaders }, signal, 1_800);
      if (!nested.ok) throw new Error(`HTTP ${nested.status}`);
      manifest = await nested.text();
      const segment = firstMediaUrl(manifest);
      if (!segment) throw new Error('播放清单没有媒体分片');
      target = new URL(segment, nested.url).toString();
    } else {
      const segment = firstMediaUrl(manifest);
      if (!segment) throw new Error('播放清单没有媒体分片');
      target = new URL(segment, first.url).toString();
    }
  }
  const sample = await fetchWithSignal(target, { headers: { ...(requestHeaders ?? {}), Range: `bytes=0-${SAMPLE_BYTES - 1}` } }, signal, 2_200);
  if (!sample.ok && sample.status !== 206) throw new Error(`HTTP ${sample.status}`);
  const measured = await sampleResponse(sample);
  if (!measured.bytes) throw new Error('媒体分片为空');
  const inferred = /(2160|1440|1080|960|720|608|576|480)p?|(?:\d{3,4})x(2160|1440|1080|960|720|608|576|480)/i.exec(candidate.name);
  height ||= Number(inferred?.[1] ?? inferred?.[2] ?? 0);
  return {
    ok: true,
    latencyMs: Math.round(performance.now() - started),
    width,
    height,
    bandwidthMbps,
    throughputMbps: measured.bytes * 8 / measured.elapsedMs / 1_000,
  };
}

function historicalPriority(candidate: RouteCandidate): number {
  const health = healthByOrigin.get(routeKey(candidate.url));
  if (!health) return 0;
  return (health.successes / Math.max(1, health.attempts)) * 100
    - health.consecutiveFailures * 50
    - (health.cooldownUntil > Date.now() ? 200 : 0);
}

export async function rankRouteCandidates(candidates: RouteCandidate[], options: RankOptions): Promise<number[]> {
  if (candidates.length < 2) return candidates.map((candidate) => candidate.index);
  const selected = [...candidates]
    .sort((left, right) => historicalPriority(right) - historicalPriority(left) || left.index - right.index)
    .slice(0, MAX_PROBE_LINES);
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), options.budgetMs ?? 3_500);
  try {
    const probed = await Promise.all(selected.map(async (candidate) => {
      try {
        const metrics = await probeCandidate(candidate, options, controller.signal);
        const health = updateHealth(candidate.url, true, metrics.latencyMs, metrics.throughputMbps);
        return { index: candidate.index, metrics, health };
      } catch {
        const health = updateHealth(candidate.url, false);
        return { index: candidate.index, metrics: { ok: false, latencyMs: options.budgetMs ?? 3_500, width: 0, height: 0, bandwidthMbps: 0, throughputMbps: 0 }, health };
      }
    }));
    const ranked = rankRouteMetrics(probed);
    const rankedSet = new Set(ranked);
    return [...ranked, ...candidates.filter((candidate) => !rankedSet.has(candidate.index)).map((candidate) => candidate.index)];
  } finally {
    clearTimeout(timeout);
  }
}

export function episodeForLine(line: PlayLine, episodeName: string, episodeIndex: number) {
  const normalized = episodeName.normalize('NFKC').replace(/\s+/g, '').toLowerCase();
  const exact = line.episodes.find((episode) => episode.name.normalize('NFKC').replace(/\s+/g, '').toLowerCase() === normalized);
  if (exact) return exact;
  const ordinal = Number(episodeName.match(/\d+/)?.[0]);
  if (Number.isFinite(ordinal)) {
    const byOrdinal = line.episodes.find((episode) => Number(episode.name.match(/\d+/)?.[0]) === ordinal);
    if (byOrdinal) return byOrdinal;
  }
  return line.episodes[Math.min(Math.max(0, episodeIndex), Math.max(0, line.episodes.length - 1))];
}
