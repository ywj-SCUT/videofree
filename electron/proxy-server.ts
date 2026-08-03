import http from 'node:http';
import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { URL } from 'node:url';
import path from 'node:path';
import sharp from 'sharp';
import { fetch as undiciFetch, ProxyAgent } from 'undici';

const defaultHeaders = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131 Safari/537.36',
  Accept: '*/*',
};

function proxiedUrl(port: number, target: string, referer?: string): string {
  const params = new URLSearchParams({ url: target });
  if (referer) params.set('referer', referer);
  return `http://127.0.0.1:${port}/stream?${params}`;
}

function rewriteManifest(manifest: string, manifestUrl: string, port: number, referer?: string): string {
  const base = new URL(manifestUrl);
  return manifest.split(/\r?\n/).map((line) => {
    const trimmed = line.trim();
    if (!trimmed) return line;
    if (trimmed.startsWith('#')) {
      return line.replace(/URI="([^"]+)"/g, (_match, uri: string) => {
        const absolute = new URL(uri, base).toString();
        return `URI="${proxiedUrl(port, absolute, referer ?? manifestUrl)}"`;
      });
    }
    try {
      return proxiedUrl(port, new URL(trimmed, base).toString(), referer ?? manifestUrl);
    } catch {
      return line;
    }
  }).join('\n');
}

function imageDimension(value: string | null, fallback: number): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? Math.min(1920, Math.max(64, Math.round(parsed))) : fallback;
}

async function downloadImage(target: string, dispatcher?: ProxyAgent): Promise<Buffer> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 12_000);
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
    return await downloadImage(target, dispatcher);
  } catch {
    return downloadImage(target);
  }
}

export async function startProxyServer(cacheDirectory: string): Promise<{ port: number; close: () => Promise<void> }> {
  let port = 0;
  await mkdir(cacheDirectory, { recursive: true });
  const outboundProxy = new ProxyAgent(process.env.HTTPS_PROXY ?? process.env.HTTP_PROXY ?? 'http://127.0.0.1:7890');
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
            pending = fetchImage(target, outboundProxy)
              .then((input) => sharp(input, { failOn: 'warning', limitInputPixels: 50_000_000 })
                .rotate()
                .resize(width, height, { fit: 'cover', position: 'attention', kernel: sharp.kernel.lanczos3 })
                .sharpen({ sigma: 0.8 })
                .webp({ quality: 88, effort: 4 })
                .toBuffer())
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
      const headers: Record<string, string> = { ...defaultHeaders };
      const referer = incoming.searchParams.get('referer');
      if (referer) headers.Referer = referer;
      if (request.headers.range) headers.Range = request.headers.range;
      const upstream = await fetch(target, { headers, redirect: 'follow' });
      if (!upstream.ok && upstream.status !== 206) {
        response.writeHead(upstream.status).end(`Upstream HTTP ${upstream.status}`);
        return;
      }
      const contentType = upstream.headers.get('content-type') ?? '';
      const isManifest = /mpegurl|m3u8/i.test(contentType) || new URL(target).pathname.toLowerCase().endsWith('.m3u8');
      if (isManifest) {
        const manifest = await upstream.text();
        response.writeHead(200, {
          'Content-Type': 'application/vnd.apple.mpegurl; charset=utf-8',
          'Cache-Control': 'no-cache',
        });
        response.end(rewriteManifest(manifest, upstream.url || target, port, referer ?? target));
        return;
      }
      const forwarded = ['content-type', 'content-length', 'content-range', 'accept-ranges', 'cache-control'];
      for (const name of forwarded) {
        const value = upstream.headers.get(name);
        if (value) response.setHeader(name, value);
      }
      response.statusCode = upstream.status;
      if (!upstream.body) {
        response.end();
        return;
      }
      const reader = upstream.body.getReader();
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        if (!response.write(Buffer.from(value))) await new Promise((resolve) => response.once('drain', resolve));
      }
      response.end();
    } catch (error) {
      if (!response.headersSent) response.writeHead(502, { 'Content-Type': 'text/plain; charset=utf-8' });
      response.end(error instanceof Error ? error.message : 'Proxy error');
    }
  });

  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => resolve());
  });
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('无法启动本地代理');
  port = address.port;
  return {
    port,
    close: async () => {
      await new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
      await outboundProxy.close();
    },
  };
}
