import { fetch as undiciFetch, ProxyAgent } from 'undici';
import { filterHlsManifest } from '../../../../electron/hls-filter';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const outboundProxy = new ProxyAgent(process.env.VIDEOGET_PROXY ?? process.env.HTTPS_PROXY ?? process.env.HTTP_PROXY ?? 'http://127.0.0.1:7890');
const defaultHeaders = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131 Safari/537.36',
  Accept: '*/*',
};

function proxyUrl(target: string, referer: string, filterAds = false): string {
  const search = new URLSearchParams({ url: target, referer });
  if (filterAds) search.set('filterAds', '1');
  return `/api/proxy?${search.toString()}`;
}

function rewriteManifest(manifest: string, manifestUrl: string, referer: string, filterAds = false): string {
  return manifest.split(/\r?\n/).map((line) => {
    const trimmed = line.trim();
    if (!trimmed) return line;
    if (trimmed.startsWith('#')) {
      return line.replace(/URI="([^"]+)"/g, (_match, uri: string) => `URI="${proxyUrl(new URL(uri, manifestUrl).toString(), referer, filterAds)}"`);
    }
    return proxyUrl(new URL(trimmed, manifestUrl).toString(), referer, filterAds);
  }).join('\n');
}

async function fetchUpstream(target: string, headers: Record<string, string>) {
  const directController = new AbortController();
  const directTimeout = setTimeout(() => directController.abort(), 5_000);
  try {
    const direct = await undiciFetch(target, { headers, redirect: 'follow', signal: directController.signal });
    if (direct.ok || direct.status === 206) return direct;
    await direct.body?.cancel();
  } catch {
    // Retry through the configured local proxy.
  } finally {
    clearTimeout(directTimeout);
  }
  return undiciFetch(target, { headers, redirect: 'follow', dispatcher: outboundProxy, signal: AbortSignal.timeout(20_000) });
}

export async function GET(request: Request) {
  const incoming = new URL(request.url);
  const target = incoming.searchParams.get('url') ?? '';
  if (!/^https?:\/\//i.test(target)) return new Response('Invalid target', { status: 400 });
  try {
    const referer = incoming.searchParams.get('referer') ?? target;
    const filterAds = incoming.searchParams.get('filterAds') === '1';
    const headers: Record<string, string> = { ...defaultHeaders, Referer: referer };
    const range = request.headers.get('range');
    if (range) headers.Range = range;
    const upstream = await fetchUpstream(target, headers);
    if (!upstream.ok && upstream.status !== 206) return new Response(`Upstream HTTP ${upstream.status}`, { status: upstream.status });
    const contentType = upstream.headers.get('content-type') ?? '';
    const manifest = /mpegurl|m3u8/i.test(contentType) || new URL(target).pathname.toLowerCase().endsWith('.m3u8');
    if (manifest) {
      const effectiveUrl = upstream.url || target;
      const original = await upstream.text();
      const filtered = filterAds ? filterHlsManifest(original) : { manifest: original, removedSegments: 0, removedDuration: 0, removedMarkers: 0 };
      return new Response(rewriteManifest(filtered.manifest, effectiveUrl, effectiveUrl, filterAds), {
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
