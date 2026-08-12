import { fetch as undiciFetch, ProxyAgent } from 'undici';
import { filterHlsManifest } from '../../../../electron/hls-filter';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const outboundProxy = new ProxyAgent(process.env.VIDEOGET_PROXY ?? process.env.HTTPS_PROXY ?? process.env.HTTP_PROXY ?? 'http://127.0.0.1:7890');
const defaultHeaders = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131 Safari/537.36',
  Accept: '*/*',
};
const proxyPreferredUntil = new Map<string, number>();

function proxyUrl(target: string, referer: string, filterAds = false, customHeaders?: Record<string, string>): string {
  const search = new URLSearchParams({ url: target, referer });
  if (filterAds) search.set('filterAds', '1');
  if (customHeaders && Object.keys(customHeaders).length) search.set('headers', JSON.stringify(customHeaders));
  return `/api/proxy?${search.toString()}`;
}

function rewriteManifest(manifest: string, manifestUrl: string, referer: string, filterAds = false, customHeaders?: Record<string, string>): string {
  return manifest.split(/\r?\n/).map((line) => {
    const trimmed = line.trim();
    if (!trimmed) return line;
    if (trimmed.startsWith('#')) {
      return line.replace(/URI="([^"]+)"/g, (_match, uri: string) => `URI="${proxyUrl(new URL(uri, manifestUrl).toString(), referer, filterAds, customHeaders)}"`);
    }
    return proxyUrl(new URL(trimmed, manifestUrl).toString(), referer, filterAds, customHeaders);
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

async function fetchWithHeaderTimeout(target: string, headers: Record<string, string>, signal: AbortSignal, timeoutMs: number, dispatcher?: ProxyAgent) {
  const timeoutController = new AbortController();
  const timeout = setTimeout(() => timeoutController.abort(), timeoutMs);
  try {
    const response = await undiciFetch(target, { headers, redirect: 'follow', dispatcher, signal: AbortSignal.any([signal, timeoutController.signal]) });
    clearTimeout(timeout);
    return response;
  } catch (error) {
    clearTimeout(timeout);
    throw error;
  }
}

async function fetchUpstream(target: string, headers: Record<string, string>, signal: AbortSignal) {
  const origin = new URL(target).origin;
  if ((proxyPreferredUntil.get(origin) ?? 0) > Date.now()) {
    try {
      const proxied = await fetchWithHeaderTimeout(target, headers, signal, 20_000, outboundProxy);
      if (proxied.ok || proxied.status === 206) return proxied;
      await proxied.body?.cancel();
    } catch (error) {
      if (signal.aborted) throw error;
    }
    proxyPreferredUntil.delete(origin);
  }
  try {
    const direct = await fetchWithHeaderTimeout(target, headers, signal, 5_000);
    if (direct.ok || direct.status === 206) return direct;
    await direct.body?.cancel();
  } catch (error) {
    if (signal.aborted) throw error;
    // Retry through the configured local proxy.
  }
  const proxied = await fetchWithHeaderTimeout(target, headers, signal, 20_000, outboundProxy);
  if (proxied.ok || proxied.status === 206) proxyPreferredUntil.set(origin, Date.now() + 5 * 60_000);
  return proxied;
}

export async function GET(request: Request) {
  const incoming = new URL(request.url);
  const target = incoming.searchParams.get('url') ?? '';
  if (!/^https?:\/\//i.test(target)) return new Response('Invalid target', { status: 400 });
  try {
    const referer = incoming.searchParams.get('referer') ?? target;
    const filterAds = incoming.searchParams.get('filterAds') === '1';
    const customHeaders = playbackHeaders(incoming.searchParams.get('headers'));
    const headers: Record<string, string> = { ...defaultHeaders, ...customHeaders, Referer: customHeaders.Referer ?? customHeaders.referer ?? referer };
    const range = request.headers.get('range');
    if (range) headers.Range = range;
    const upstream = await fetchUpstream(target, headers, request.signal);
    if (!upstream.ok && upstream.status !== 206) return new Response(`Upstream HTTP ${upstream.status}`, { status: upstream.status });
    const contentType = upstream.headers.get('content-type') ?? '';
    const manifest = /mpegurl|m3u8/i.test(contentType) || new URL(target).pathname.toLowerCase().endsWith('.m3u8');
    if (manifest) {
      const effectiveUrl = upstream.url || target;
      const original = await upstream.text();
      const filtered = filterAds ? filterHlsManifest(original) : { manifest: original, removedSegments: 0, removedDuration: 0, removedMarkers: 0 };
      return new Response(rewriteManifest(filtered.manifest, effectiveUrl, effectiveUrl, filterAds, customHeaders), {
        headers: {
          'Content-Type': 'application/vnd.apple.mpegurl; charset=utf-8', 'Cache-Control': 'no-cache',
          'X-VideoGET-Ad-Segments': String(filtered.removedSegments),
          'X-VideoGET-Ad-Seconds': filtered.removedDuration.toFixed(3),
          'X-VideoGET-Ad-Markers': String(filtered.removedMarkers),
        },
      });
    }
    const responseHeaders = new Headers();
    for (const name of ['content-type', 'content-length', 'content-range', 'accept-ranges', 'cache-control']) {
      const value = upstream.headers.get(name);
      if (value) responseHeaders.set(name, value);
    }
    return new Response(upstream.body as unknown as BodyInit, { status: upstream.status, headers: responseHeaders });
  } catch (error) {
    return new Response(error instanceof Error ? error.message : String(error), { status: 502 });
  }
}
