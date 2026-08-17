import http from 'node:http';
import { URL } from 'node:url';

export interface PrefetchProgress {
  total: number;
  cached: number;
  fetched: number;
  failed: number;
  bytes: number;
  done: boolean;
  status: 'running' | 'completed' | 'failed' | 'stopped' | 'idle';
}

type ProgressCallback = (progress: PrefetchProgress) => void;

interface TimedSegment {
  url: string;
  duration: number;
}

function extractTimedSegments(manifest: string): TimedSegment[] {
  const lines = manifest.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  const segments: TimedSegment[] = [];
  let duration = 0;
  for (const line of lines) {
    const extinf = line.match(/^#EXTINF:([\d.]+)/i);
    if (extinf) {
      duration = Number(extinf[1]) || 0;
      continue;
    }
    if (line.startsWith('#')) continue;
    if (line.startsWith('http://127.0.0.1') || line.startsWith('http://localhost')) {
      segments.push({ url: line, duration });
    }
    duration = 0;
  }
  return segments;
}

function extractSegmentUrls(manifest: string): string[] {
  return extractTimedSegments(manifest).map((segment) => segment.url);
}

export function selectPrefetchSegmentUrls(manifest: string, limit = 24): string[] {
  const segments = extractTimedSegments(manifest);
  if (!segments.length || limit <= 0) return [];
  const selected = new Set<number>();
  const introCount = Math.min(6, segments.length, limit);
  for (let index = 0; index < introCount; index++) selected.add(index);

  let elapsed = 0;
  let nextAnchor = 5 * 60;
  for (let index = 0; index < segments.length && selected.size < limit; index++) {
    const end = elapsed + segments[index].duration;
    while (nextAnchor < end && selected.size < limit) {
      selected.add(index);
      if (index + 1 < segments.length && selected.size < limit) selected.add(index + 1);
      nextAnchor += 5 * 60;
    }
    elapsed = end;
  }

  return [...selected].sort((left, right) => left - right).map((index) => segments[index].url);
}

export function orderFullEpisodePrefetchUrls(manifest: string): string[] {
  const all = extractSegmentUrls(manifest);
  if (!all.length) return [];
  const priority = selectPrefetchSegmentUrls(manifest);
  const selected = new Set(priority);
  return [...priority, ...all.filter((url) => !selected.has(url))];
}

function isSubManifestUrl(url: string): boolean {
  try {
    const parsed = new URL(url);
    const originalUrl = parsed.searchParams.get('url') ?? '';
    return new URL(originalUrl).pathname.toLowerCase().endsWith('.m3u8');
  } catch {
    return false;
  }
}

interface HlsVariant {
  url: string;
  height: number;
  bandwidth: number;
}

export function selectPrefetchVariantUrl(manifest: string): string | null {
  const lines = manifest.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  const variants: HlsVariant[] = [];
  for (let index = 0; index < lines.length; index++) {
    const streamInfo = lines[index].match(/^#EXT-X-STREAM-INF:(.+)$/i);
    if (!streamInfo) continue;
    const url = lines.slice(index + 1).find((line) => !line.startsWith('#'));
    if (!url || !isSubManifestUrl(url)) continue;
    const resolution = streamInfo[1].match(/(?:^|,)RESOLUTION=(\d+)x(\d+)(?:,|$)/i);
    const bandwidth = streamInfo[1].match(/(?:^|,)BANDWIDTH=(\d+)(?:,|$)/i);
    variants.push({
      url,
      height: Number(resolution?.[2] ?? 0),
      bandwidth: Number(bandwidth?.[1] ?? 0),
    });
  }
  if (!variants.length) return null;

  const capped = variants.filter((variant) => variant.height > 0 && variant.height <= 1080);
  if (capped.length) {
    capped.sort((left, right) => right.height - left.height || right.bandwidth - left.bandwidth);
    return capped[0].url;
  }
  const unknown = variants.filter((variant) => variant.height === 0);
  if (unknown.length) {
    unknown.sort((left, right) => right.bandwidth - left.bandwidth);
    return unknown[0].url;
  }
  variants.sort((left, right) => left.height - right.height || right.bandwidth - left.bandwidth);
  return variants[0].url;
}

function streamUrlToPrefetchUrl(streamUrl: string): string {
  return streamUrl.replace('/stream?', '/prefetch?');
}

export class PrefetchManager {
  private abortController: AbortController | null = null;
  private progress: PrefetchProgress = { total: 0, cached: 0, fetched: 0, failed: 0, bytes: 0, done: false, status: 'idle' };
  private onProgress: ProgressCallback | null = null;

  setProgressCallback(cb: ProgressCallback): void {
    this.onProgress = cb;
  }

  get currentProgress(): PrefetchProgress {
    return { ...this.progress };
  }

  isRunning(): boolean {
    return this.progress.status === 'running';
  }

  async start(m3u8Url: string, proxyPort: number, headers?: Record<string, string>, filterAds = false): Promise<void> {
    this.stop();
    this.abortController = new AbortController();
    const signal = this.abortController.signal;
    this.progress = { total: 0, cached: 0, fetched: 0, failed: 0, bytes: 0, done: false, status: 'running' };
    this.emitProgress();

    try {
      const params = new URLSearchParams({ url: m3u8Url });
      if (headers && Object.keys(headers).length) params.set('headers', JSON.stringify(headers));
      if (filterAds) params.set('filterAds', '1');
      const manifestProxyUrl = `http://127.0.0.1:${proxyPort}/stream?${params}`;
      const manifestResp = await this.fetchText(manifestProxyUrl, signal);
      let mediaManifest = manifestResp;

      const variantUrl = selectPrefetchVariantUrl(manifestResp);
      if (variantUrl) {
        mediaManifest = await this.fetchText(variantUrl, signal);
      }

      const priorityUrls = selectPrefetchSegmentUrls(mediaManifest);
      const segmentUrls = orderFullEpisodePrefetchUrls(mediaManifest);

      if (segmentUrls.length === 0) {
        this.progress.done = true;
        this.progress.status = 'completed';
        this.emitProgress();
        return;
      }

      this.progress.total = segmentUrls.length;
      this.emitProgress();

      const fetchBatch = async (urls: string[], concurrency: number) => {
        let index = 0;
        const worker = async () => {
          while (index < urls.length) {
            if (signal.aborted) return;
            const segUrl = urls[index++];
            const prefetchUrl = streamUrlToPrefetchUrl(segUrl);
            try {
              const resp = await this.fetchJson(prefetchUrl, signal);
              const size = Number(resp.size ?? 0);
              if (resp.cached) this.progress.cached++;
              else if (size > 0) this.progress.fetched++;
              else this.progress.failed++;
              this.progress.bytes += size;
            } catch {
              if (signal.aborted) return;
              this.progress.failed++;
            }
            this.emitProgress();
          }
        };
        await Promise.all(Array.from({ length: Math.min(concurrency, urls.length) }, () => worker()));
      };

      await fetchBatch(priorityUrls, 2);
      if (!signal.aborted) await fetchBatch(segmentUrls.slice(priorityUrls.length), 1);

      this.progress.done = true;
      this.progress.status = signal.aborted ? 'stopped' : 'completed';
      this.emitProgress();
    } catch {
      if (!signal.aborted) {
        this.progress.failed++;
        this.progress.done = true;
        this.progress.status = 'failed';
        this.emitProgress();
      }
    }
  }

  stop(): void {
    if (this.abortController) {
      this.abortController.abort();
      this.abortController = null;
    }
    if (this.progress.status === 'running') {
      this.progress.status = 'stopped';
      this.progress.done = true;
      this.emitProgress();
    }
  }

  private emitProgress(): void {
    if (this.onProgress) this.onProgress({ ...this.progress });
  }

  private async fetchText(url: string, signal: AbortSignal): Promise<string> {
    const resp = await fetch(url, { signal });
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    return resp.text();
  }

  private async fetchJson(url: string, signal: AbortSignal): Promise<{ cached: boolean; size: number }> {
    const resp = await fetch(url, { signal });
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    return resp.json();
  }
}
