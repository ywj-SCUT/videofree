import http from 'node:http';
import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { URL } from 'node:url';
import path from 'node:path';
import sharp from 'sharp';
import { fetch as undiciFetch, ProxyAgent } from 'undici';
import { filterHlsManifest } from './hls-filter.js';
import { MAX_CACHE_ENTRY_SIZE, VideoCache, isCacheableSegment } from './video-cache.js';

const defaultHeaders = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131 Safari/537.36',
  Accept: '*/*',
};

function proxiedUrl(port: number, target: string, referer?: string, filterAds = false, customHeaders?: Record<string, string>): string {
  const params = new URLSearchParams({ url: target });
  if (referer) params.set('referer', referer);
  if (filterAds) params.set('filterAds', '1');
  if (customHeaders && Object.keys(customHeaders).length) params.set('headers', JSON.stringify(customHeaders));
  return `http://127.0.0.1:${port}/stream?${params}`;
}

function rewriteManifest(manifest: string, manifestUrl: string, port: number, referer?: string, filterAds = false, customHeaders?: Record<string, string>): string {
  const base = new URL(manifestUrl);
  return manifest.split(/\r?\n/).map((line) => {
    const trimmed = line.trim();
    if (!trimmed) return line;
    if (trimmed.startsWith('#')) {
      return line.replace(/URI="([^"]+)"/g, (_match, uri: string) => {
        const absolute = new URL(uri, base).toString();
        return `URI="${proxiedUrl(port, absolute, referer ?? manifestUrl, filterAds, customHeaders)}"`;
      });
    }
    try {
      return proxiedUrl(port, new URL(trimmed, base).toString(), referer ?? manifestUrl, filterAds, customHeaders);
    } catch {
      return line;
    }
  }).join('\n');
}

function playbackHeaders(value: string | null): Record<string, string> {
  if (!value || value.length > 12_000) return {};
  try {
    const parsed = JSON.parse(value) as Record<string, unknown>;
    const blocked = new Set(['host', 'content-length', 'connection', 'proxy-authorization', 'transfer-encoding', 'range']);
    return Object.fromEntries(Object.entries(parsed).flatMap(([name, raw]) => {
      const key = name.trim();
      const headerValue = String(raw ?? '').trim();
      if (!/^[a-z0-9-]{1,64}$/i.test(key) || blocked.has(key.toLowerCase()) || !headerValue || headerValue.length > 4096 || /[\r\n]/.test(headerValue)) return [];
      return [[key, headerValue]];
    }));
  } catch {
    return {};
  }
}

function imageDimension(value: string | null, fallback: number): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? Math.min(1920, Math.max(64, Math.round(parsed))) : fallback;
}

async function downloadImage(target: string, dispatcher?: ProxyAgent, timeoutMs = 12_000): Promise<Buffer> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const upstream = await undiciFetch(target, { headers: defaultHeaders, redirect: 'follow', signal: controller.signal, dispatcher });
    if (!upstream.ok) throw new Error(`Upstream HTTP ${upstream.status}`);
    const declaredLength = Number(upstream.headers.get('content-length') ?? 0);
    if (declaredLength > 20 * 1024 * 1024) throw new Error('Image exceeds 20 MB');
    const buffer = Buffer.from(await upstream.arrayBuffer());
    if (!buffer.length || buffer.length > 20 * 1024 * 1024) throw new Error('Invalid image size');
    return buffer;
  } finally {
    clearTimeout(timeout);
  }
}

async function fetchImage(target: string, dispatcher: ProxyAgent): Promise<Buffer> {
  try {
    return await downloadImage(target, undefined, 4_500);
  } catch {
    return downloadImage(target, dispatcher);
  }
}

function createLimiter(limit: number): <T>(task: () => Promise<T>) => Promise<T> {
  let active = 0;
  const waiting: Array<() => void> = [];
  return async <T>(task: () => Promise<T>): Promise<T> => {
    if (active >= limit) await new Promise<void>((resolve) => waiting.push(resolve));
    active++;
    try {
      return await task();
    } finally {
      active--;
      waiting.shift()?.();
    }
  };
}

function waitForDrain(response: http.ServerResponse): Promise<boolean> {
  return new Promise((resolve) => {
    const onDrain = () => { cleanup(); resolve(true); };
    const onClose = () => { cleanup(); resolve(false); };
    const cleanup = () => {
      response.off('drain', onDrain);
      response.off('close', onClose);
    };
    response.once('drain', onDrain);
    response.once('close', onClose);
  });
}

async function fetchHeaders(target: string, headers: Record<string, string>, dispatcher?: ProxyAgent, timeoutMs = 5_000, signal?: AbortSignal) {
  const timeoutController = new AbortController();
  const timeout = setTimeout(() => timeoutController.abort(), timeoutMs);
  try {
    const fetchSignal = signal ? AbortSignal.any([signal, timeoutController.signal]) : timeoutController.signal;
    const result = await undiciFetch(target, { headers, redirect: 'follow', dispatcher, signal: fetchSignal });
    clearTimeout(timeout);
    return result;
  } catch (error) {
    clearTimeout(timeout);
    throw error;
  }
}

interface RoutePreference { route: 'proxy'; expiresAt: number }

async function fetchStream(target: string, headers: Record<string, string>, dispatcher: ProxyAgent, routePreferences: Map<string, RoutePreference>, signal: AbortSignal) {
  const origin = new URL(target).origin;
  const preference = routePreferences.get(origin);
  if (preference && preference.expiresAt > Date.now()) {
    try {
      const proxied = await fetchHeaders(target, headers, dispatcher, 8_000, signal);
      if (proxied.ok || proxied.status === 206) return proxied;
      await proxied.body?.cancel();
    } catch (error) {
      if (signal.aborted) throw error;
    }
    routePreferences.delete(origin);
  }
  try {
    const direct = await fetchHeaders(target, headers, undefined, 1_500, signal);
    if (direct.ok || direct.status === 206) return direct;
    await direct.body?.cancel();
  } catch (error) {
    if (signal.aborted) throw error;
    // Fall through to the configured local proxy.
  }
  const proxied = await fetchHeaders(target, headers, dispatcher, 8_000, signal);
  if (proxied.ok || proxied.status === 206) {
    routePreferences.set(origin, { route: 'proxy', expiresAt: Date.now() + 10 * 60_000 });
  }
  return proxied;
}

function parseRange(range: string, total: number): { start: number; end: number } | null {
  const match = /bytes=(\d+)-(\d*)/.exec(range);
  if (!match) return null;
  const start = parseInt(match[1], 10);
  const end = match[2] ? parseInt(match[2], 10) : total - 1;
  if (start > end || start >= total) return null;
  return { start, end: Math.min(end, total - 1) };
}

function cacheIdentity(target: string, headers: Record<string, string>, range?: string): string {
  const headerKey = Object.entries(headers)
    .filter(([name]) => !['user-agent', 'accept', 'range'].includes(name.toLowerCase()))
    .sort(([left], [right]) => left.toLowerCase().localeCompare(right.toLowerCase()))
    .map(([name, value]) => `${name.toLowerCase()}:${value}`)
    .join('\n');
  return headerKey || range ? `${target}\n${headerKey}\nrange-v2:${range ?? ''}` : target;
}

function cachedRangeHeader(range: string, size: number): string | null {
  const match = /^bytes=(\d+)-(\d*)$/i.exec(range);
  if (!match) return null;
  const start = Number(match[1]);
  const requestedEnd = match[2] ? Number(match[2]) : start + size - 1;
  return `bytes ${start}-${Math.min(requestedEnd, start + size - 1)}/*`;
}

function isValidPartialResponse(range: string, status: number, contentRange: string | null): boolean {
  if (status !== 206 || !contentRange) return false;
  const requested = /^bytes=(\d+)-(\d*)$/i.exec(range);
  const received = /^bytes\s+(\d+)-(\d+)\/(?:\d+|\*)$/i.exec(contentRange.trim());
  if (!requested || !received) return false;
  const requestedStart = Number(requested[1]);
  const requestedEnd = requested[2] ? Number(requested[2]) : null;
  const receivedStart = Number(received[1]);
  const receivedEnd = Number(received[2]);
  return receivedStart === requestedStart
    && receivedEnd >= receivedStart
    && (requestedEnd === null || receivedEnd <= requestedEnd);
}

export async function startProxyServer(cacheDirectory: string, videoCache?: VideoCache): Promise<{ port: number; close: () => Promise<void> }> {
  let port = 0;
  await mkdir(cacheDirectory, { recursive: true });
  const proxyUrl = process.env.VIDEOGET_PROXY ?? process.env.HTTPS_PROXY ?? process.env.HTTP_PROXY ?? 'http://127.0.0.1:7890';
  const imageOutboundProxy = new ProxyAgent(proxyUrl);
  const streamOutboundProxy = new ProxyAgent(proxyUrl);
  const streamRoutePreferences = new Map<string, RoutePreference>();
  const limitImages = createLimiter(4);
  const pendingImages = new Map<string, Promise<Buffer>>();
  const server = http.createServer(async (request, response) => {
    response.setHeader('Access-Control-Allow-Origin', '*');
    response.setHeader('Access-Control-Allow-Headers', '*');
    if (request.method === 'OPTIONS') {
      response.writeHead(204).end();
      return;
    }
    const incoming = new URL(request.url ?? '/', 'http://127.0.0.1');
    if (incoming.pathname === '/health') {
      response.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ ok: true }));
      return;
    }
    if (incoming.pathname === '/cache-stats' && videoCache) {
      response.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({
        size: videoCache.size,
        count: videoCache.count,
        sizeMB: Math.round(videoCache.size / 1024 / 1024 * 100) / 100,
      }));
      return;
    }
    if (incoming.pathname === '/image') {
      const target = incoming.searchParams.get('url');
      if (!target || !/^https?:\/\//i.test(target)) {
        response.writeHead(400).end('Invalid target');
        return;
      }
      const width = imageDimension(incoming.searchParams.get('w'), 800);
      const height = imageDimension(incoming.searchParams.get('h'), 1200);
      const cacheKey = createHash('sha256').update(`${target}\n${width}x${height}`).digest('hex');
      const cachePath = path.join(cacheDirectory, `${cacheKey}.webp`);
      try {
        let image: Buffer;
        try {
          image = await readFile(cachePath);
        } catch {
          let pending = pendingImages.get(cacheKey);
          if (!pending) {
            pending = limitImages(() => fetchImage(target, imageOutboundProxy)
              .then((input) => sharp(input, { failOn: 'warning', limitInputPixels: 50_000_000 })
                .rotate()
                .resize(width, height, { fit: 'cover', position: 'attention', kernel: sharp.kernel.lanczos3 })
                .sharpen({ sigma: 0.8 })
                .webp({ quality: 88, effort: 4 })
                .toBuffer()))
              .then(async (output) => { await writeFile(cachePath, output); return output; })
              .finally(() => pendingImages.delete(cacheKey));
            pendingImages.set(cacheKey, pending);
          }
          image = await pending;
        }
        response.writeHead(200, {
          'Content-Type': 'image/webp',
          'Content-Length': image.length,
          'Cache-Control': 'public, max-age=604800, immutable',
        }).end(image);
      } catch (error) {
        response.writeHead(502, { 'Content-Type': 'text/plain; charset=utf-8' });
        response.end(error instanceof Error ? error.message : 'Image processing error');
      }
      return;
    }
    if (incoming.pathname === '/prefetch' && videoCache) {
      const target = incoming.searchParams.get('url');
      if (!target || !/^https?:\/\//i.test(target)) {
        response.writeHead(400).end('Invalid target');
        return;
      }
      try {
        const customHeaders = playbackHeaders(incoming.searchParams.get('headers'));
        const headers: Record<string, string> = { ...defaultHeaders, ...customHeaders };
        const referer = incoming.searchParams.get('referer');
        if (referer) headers.Referer = referer;
        const cacheKey = cacheIdentity(target, headers);
        if (videoCache.has(cacheKey)) {
          response.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ cached: true, size: 0 }));
          return;
        }
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 30_000);
        try {
          const upstream = await fetchStream(target, headers, streamOutboundProxy, streamRoutePreferences, controller.signal);
          clearTimeout(timeout);
          if (!upstream.ok && upstream.status !== 206) {
            response.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ cached: false, size: 0 }));
            return;
          }
          const contentType = upstream.headers.get('content-type') ?? '';
          if (isCacheableSegment(target, contentType)) {
            const buffer = Buffer.from(await upstream.arrayBuffer());
            if (buffer.length > 0 && buffer.length <= 100 * 1024 * 1024) {
              await videoCache.put(cacheKey, buffer);
              response.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ cached: false, size: buffer.length }));
              return;
            }
          }
          response.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ cached: false, size: 0 }));
        } catch {
          clearTimeout(timeout);
          response.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ cached: false, size: 0 }));
        }
      } catch (error) {
        response.writeHead(502, { 'Content-Type': 'application/json' }).end(JSON.stringify({ cached: false, size: 0, error: String(error) }));
      }
      return;
    }

    if (incoming.pathname !== '/stream') {
      response.writeHead(404).end('Not found');
      return;
    }
    const target = incoming.searchParams.get('url');
    if (!target || !/^https?:\/\//i.test(target)) {
      response.writeHead(400).end('Invalid target');
      return;
    }
    try {
      const controller = new AbortController();
      request.once('aborted', () => controller.abort());
      response.once('close', () => {
        if (!response.writableEnded) controller.abort();
      });
      const customHeaders = playbackHeaders(incoming.searchParams.get('headers'));
      const headers: Record<string, string> = { ...defaultHeaders, ...customHeaders };
      const referer = incoming.searchParams.get('referer');
      const filterAds = incoming.searchParams.get('filterAds') === '1';
      if (referer) headers.Referer = referer;
      const range = request.headers.range;
      const cacheKey = cacheIdentity(target, headers, range);

      // --- Cache fast-path for video segments ---
      if (videoCache) {
        const cached = await videoCache.get(cacheKey);
        if (cached) {
          const cachedRange = range ? cachedRangeHeader(range, cached.length) : null;
          response.writeHead(range ? 206 : 200, {
            'Content-Type': 'application/octet-stream',
            'Content-Length': cached.length,
            'Accept-Ranges': 'bytes',
            ...(cachedRange ? { 'Content-Range': cachedRange } : {}),
            'Cache-Control': 'public, max-age=86400, immutable',
            'X-VideoGET-Cache': 'HIT',
          });
          response.end(cached);
          return;
        }
      }

      // Forward Range header for upstream requests
      if (range) headers.Range = range;
      const upstream = await fetchStream(target, headers, streamOutboundProxy, streamRoutePreferences, controller.signal);
      if (!upstream.ok && upstream.status !== 206) {
        response.writeHead(upstream.status).end(`Upstream HTTP ${upstream.status}`);
        return;
      }
      const contentType = upstream.headers.get('content-type') ?? '';
      const isManifest = /mpegurl|m3u8/i.test(contentType) || new URL(target).pathname.toLowerCase().endsWith('.m3u8');
      if (isManifest) {
        const manifest = await upstream.text();
        const filtered = filterAds ? filterHlsManifest(manifest) : { manifest, removedSegments: 0, removedDuration: 0, removedMarkers: 0 };
        response.writeHead(200, {
          'Content-Type': 'application/vnd.apple.mpegurl; charset=utf-8',
          'Cache-Control': 'no-cache',
          'X-VideoGET-Ad-Segments': String(filtered.removedSegments),
          'X-VideoGET-Ad-Seconds': filtered.removedDuration.toFixed(3),
          'X-VideoGET-Ad-Markers': String(filtered.removedMarkers),
        });
        response.end(rewriteManifest(filtered.manifest, upstream.url || target, port, referer ?? target, filterAds, customHeaders));
        return;
      }

      // --- Cache write-path for cacheable segments ---
      const declaredLength = Number(upstream.headers.get('content-length') ?? 0);
      const cacheableStatus = range
        ? isValidPartialResponse(range, upstream.status, upstream.headers.get('content-range'))
        : upstream.status === 200;
      let cacheable = Boolean(
        videoCache
        && cacheableStatus
        && isCacheableSegment(target, contentType)
        && (!declaredLength || declaredLength <= MAX_CACHE_ENTRY_SIZE),
      );

      const forwarded = ['content-type', 'content-length', 'content-range', 'accept-ranges', 'cache-control'];
      for (const name of forwarded) {
        const value = upstream.headers.get(name);
        if (value) response.setHeader(name, value);
      }
      if (cacheable) response.setHeader('X-VideoGET-Cache', 'MISS');
      response.statusCode = upstream.status;
      if (!upstream.body) {
        response.end();
        return;
      }
      const chunks: Buffer[] = [];
      let cachedBytes = 0;
      const reader = upstream.body.getReader();
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        const chunk = Buffer.from(value);
        if (cacheable) {
          cachedBytes += chunk.length;
          if (cachedBytes <= MAX_CACHE_ENTRY_SIZE) chunks.push(chunk);
          else {
            cacheable = false;
            chunks.length = 0;
          }
        }
        if (!response.write(chunk)) {
          if (!await waitForDrain(response)) {
            await reader.cancel();
            return;
          }
        }
      }
      response.end();
      // Persist to disk cache asynchronously after the client has received
      // all data, so streaming latency is unaffected.
      if (cacheable && chunks.length > 0) {
        void videoCache!.put(cacheKey, Buffer.concat(chunks));
      }
    } catch (error) {
      if (request.aborted || response.destroyed) return;
      if (!response.headersSent) response.writeHead(502, { 'Content-Type': 'text/plain; charset=utf-8' });
      response.end(error instanceof Error ? error.message : 'Proxy error');
    }
  });

  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => resolve());
  });
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('Unable to start local proxy');
  port = address.port;
  return {
    port,
    close: async () => {
      await new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
      await Promise.all([imageOutboundProxy.close(), streamOutboundProxy.close()]);
    },
  };
}

