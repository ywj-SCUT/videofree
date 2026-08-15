import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile, stat, unlink, readdir, rename } from 'node:fs/promises';
import path from 'node:path';

const MAX_CACHE_SIZE = 2 * 1024 * 1024 * 1024; // 2 GB
const MAX_SEGMENT_SIZE = 100 * 1024 * 1024; // 100 MB per segment
const EVICT_RATIO = 0.9; // Evict down to 90% of max

const CACHEABLE_EXTENSIONS = new Set([
  '.ts', '.m4s', '.aac', '.mp4', '.key', '.vtt', '.webvtt', '.srt', '.cmfv', '.cmfa',
]);

const CACHEABLE_CONTENT_TYPES = /^(video\/|audio\/|application\/octet-stream)/i;

export function isCacheableSegment(url: string, contentType: string): boolean {
  if (/mpegurl|m3u8/i.test(contentType)) return false;
  let pathname: string;
  try {
    pathname = new URL(url).pathname;
  } catch {
    return false;
  }
  if (pathname.toLowerCase().endsWith('.m3u8')) return false;
  const ext = path.extname(pathname).toLowerCase();
  if (CACHEABLE_EXTENSIONS.has(ext)) return true;
  if (CACHEABLE_CONTENT_TYPES.test(contentType)) return true;
  return false;
}

interface CacheEntry {
  size: number;
  lastAccess: number;
}

export class VideoCache {
  private readonly dir: string;
  private readonly meta = new Map<string, CacheEntry>();
  private totalSize = 0;
  private cleaning = false;
  private readonly inflight = new Map<string, Promise<Buffer | null>>();

  constructor(dir: string) {
    this.dir = dir;
  }

  async init(): Promise<void> {
    await mkdir(this.dir, { recursive: true });
    const entries = await readdir(this.dir).catch(() => [] as string[]);
    for (const entry of entries) {
      if (!/^[0-9a-f]{64}$/.test(entry)) continue;
      try {
        const stats = await stat(path.join(this.dir, entry));
        if (stats.isFile()) {
          this.meta.set(entry, { size: stats.size, lastAccess: stats.mtimeMs });
          this.totalSize += stats.size;
        }
      } catch {
        // File may have been removed concurrently; skip.
      }
    }
  }

  keyOf(url: string): string {
    return createHash('sha256').update(url).digest('hex');
  }

  has(url: string): boolean {
    return this.meta.has(this.keyOf(url));
  }

  async get(url: string): Promise<Buffer | null> {
    const key = this.keyOf(url);
    const entry = this.meta.get(key);
    if (!entry) return null;
    try {
      const data = await readFile(path.join(this.dir, key));
      this.meta.set(key, { ...entry, lastAccess: Date.now() });
      return data;
    } catch {
      this.meta.delete(key);
      return null;
    }
  }

  async getOrFetch(
    url: string,
    fetcher: () => Promise<{ status: number; buffer: Buffer; headers: Record<string, string> }>,
  ): Promise<{ status: number; buffer: Buffer; headers: Record<string, string>; cached: boolean }> {
    const cached = await this.get(url);
    if (cached) {
      return { status: 200, buffer: cached, headers: {}, cached: true };
    }
    // Deduplicate concurrent requests for the same URL
    let pending = this.inflight.get(url);
    if (!pending) {
      pending = (async () => {
        try {
          const result = await fetcher();
          if (result.status === 200 && result.buffer.length > 0 && result.buffer.length <= MAX_SEGMENT_SIZE) {
            await this.put(url, result.buffer);
          }
          return result.buffer;
        } catch {
          return null;
        }
      })();
      this.inflight.set(url, pending);
    }
    const buffer = await pending;
    this.inflight.delete(url);
    if (buffer) {
      return { status: 200, buffer, headers: {}, cached: false };
    }
    // Fallback: fetch again without caching
    const result = await fetcher();
    return { ...result, cached: false };
  }

  async put(url: string, data: Buffer): Promise<void> {
    if (data.length === 0 || data.length > MAX_SEGMENT_SIZE) return;
    const key = this.keyOf(url);
    const tempPath = path.join(this.dir, `${key}.tmp`);
    const finalPath = path.join(this.dir, key);
    try {
      await writeFile(tempPath, data);
      await rename(tempPath, finalPath);
    } catch {
      try { await unlink(tempPath); } catch {}
      return;
    }
    const old = this.meta.get(key);
    if (old) this.totalSize -= old.size;
    this.meta.set(key, { size: data.length, lastAccess: Date.now() });
    this.totalSize += data.length;
    void this.evict();
  }

  private async evict(): Promise<void> {
    if (this.totalSize <= MAX_CACHE_SIZE || this.cleaning) return;
    this.cleaning = true;
    try {
      const sorted = [...this.meta.entries()].sort((a, b) => a[1].lastAccess - b[1].lastAccess);
      while (this.totalSize > MAX_CACHE_SIZE * EVICT_RATIO && sorted.length > 0) {
        const [key, entry] = sorted.shift()!;
        try { await unlink(path.join(this.dir, key)); } catch {}
        this.meta.delete(key);
        this.totalSize -= entry.size;
      }
    } finally {
      this.cleaning = false;
    }
  }

  async clear(): Promise<void> {
    const keys = [...this.meta.keys()];
    this.meta.clear();
    this.totalSize = 0;
    await Promise.all(keys.map((key) => unlink(path.join(this.dir, key)).catch(() => {})));
  }

  get size(): number {
    return this.totalSize;
  }

  get count(): number {
    return this.meta.size;
  }
}

