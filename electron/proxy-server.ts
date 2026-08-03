import http from 'node:http';
import { URL } from 'node:url';

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

export async function startProxyServer(): Promise<{ port: number; close: () => Promise<void> }> {
  let port = 0;
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
    close: () => new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve())),
  };
}
