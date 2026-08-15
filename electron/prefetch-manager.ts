import http from 'node:http';
import { URL } from 'node:url';

export interface PrefetchProgress {
  total: number;
  cached: number;
  fetched: number;
  failed: number;
  bytes: number;
  done: boolean;
  status: 'running' | 'completed' | 'stopped' | 'idle';
}

type ProgressCallback = (progress: PrefetchProgress) => void;

function extractSegmentUrls(manifest: string): string[] {
  const lines = manifest.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  const urls: string[] = [];
  for (const line of lines) {
    if (line.startsWith('#')) continue;
    if (line.startsWith('http://127.0.0.1') || line.startsWith('http://localhost')) {
      urls.push(line);
    }
  }
  return urls;
}

function isSubManifestUrl(url: string): boolean {
  try {
    const parsed = new URL(url);
    const originalUrl = parsed.searchParams.get('url') ?? '';
    return originalUrl.toLowerCase().endsWith('.m3u8');
  } catch {
    return false;
  }
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

  async start(m3u8Url: string, proxyPort: number): Promise<void> {
    this.stop();
    this.abortController = new AbortController();
    const signal = this.abortController.signal;
    this.progress = { total: 0, cached: 0, fetched: 0, failed: 0, bytes: 0, done: false, status: 'running' };
    this.emitProgress();

    try {
      const manifestProxyUrl = `http://127.0.0.1:${proxyPort}/stream?url=${encodeURIComponent(m3u8Url)}`;
      const manifestResp = await this.fetchText(manifestProxyUrl, signal);
      let entries = extractSegmentUrls(manifestResp);

      if (entries.length > 0 && isSubManifestUrl(entries[0])) {
        const subManifestResp = await this.fetchText(entries[0], signal);
        entries = extractSegmentUrls(subManifestResp);
      }

      const segmentUrls = entries.filter((url) => !isSubManifestUrl(url));

      if (segmentUrls.length === 0) {
        this.progress.done = true;
        this.progress.status = 'completed';
        this.emitProgress();
        return;
      }

      this.progress.total = segmentUrls.length;
      this.emitProgress();

      const concurrency = 4;
      let index = 0;
      const worker = async () => {
        while (index < segmentUrls.length) {
          if (signal.aborted) return;
          const currentIndex = index++;
          const segUrl = segmentUrls[currentIndex];
          const prefetchUrl = streamUrlToPrefetchUrl(segUrl);
          try {
            const resp = await this.fetchJson(prefetchUrl, signal);
            if (resp.cached) { this.progress.cached++; } else { this.progress.fetched++; }
            this.progress.bytes += resp.size ?? 0;
          } catch {
            if (signal.aborted) return;
            this.progress.failed++;
          }
          this.emitProgress();
        }
      };

      const workers = Array.from({ length: Math.min(concurrency, segmentUrls.length) }, () => worker());
      await Promise.all(workers);

      this.progress.done = true;
      this.progress.status = signal.aborted ? 'stopped' : 'completed';
      this.emitProgress();
    } catch {
      if (!signal.aborted) {
        this.progress.done = true;
        this.progress.status = 'completed';
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