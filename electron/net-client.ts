import { fetch as undiciFetch, ProxyAgent } from 'undici';

const defaultHeaders = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131 Safari/537.36',
  Accept: '*/*',
};

interface RemoteTextOptions {
  headers?: Record<string, string>;
  method?: string;
  body?: string;
  timeoutMs?: number;
  maxBytes?: number;
}

const proxyPreferredUntil = new Map<string, number>();
const PROXY_PREFERENCE_TTL_MS = 10 * 60_000;
const DIRECT_PROBE_MAX_MS = 1_500;

async function requestText(url: string, options: RemoteTextOptions, dispatcher?: ProxyAgent): Promise<string> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), options.timeoutMs ?? 12_000);
  try {
    const response = await undiciFetch(url, {
      method: options.method ?? 'GET',
      headers: { ...defaultHeaders, ...(options.headers ?? {}) },
      body: options.body,
      redirect: 'follow',
      signal: controller.signal,
      dispatcher,
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const maxBytes = options.maxBytes ?? 20 * 1024 * 1024;
    const declaredLength = Number(response.headers.get('content-length') ?? 0);
    if (declaredLength > maxBytes) throw new Error('响应内容过大');
    const buffer = Buffer.from(await response.arrayBuffer());
    if (buffer.length > maxBytes) throw new Error('响应内容过大');
    return buffer.toString('utf8').replace(/^\uFEFF/, '');
  } finally {
    clearTimeout(timeout);
  }
}

export async function fetchRemoteText(url: string, options: RemoteTextOptions = {}): Promise<string> {
  if (!/^https?:\/\//i.test(url)) throw new Error('仅支持 HTTP/HTTPS 地址');
  const totalTimeoutMs = Math.max(250, options.timeoutMs ?? 12_000);
  const deadline = Date.now() + totalTimeoutMs;
  const origin = new URL(url).origin;
  const proxy = new ProxyAgent(process.env.VIDEOGET_PROXY ?? 'http://127.0.0.1:7890');
  const requestWithinDeadline = async (dispatcher?: ProxyAgent, limitMs = totalTimeoutMs) => {
    const remainingMs = deadline - Date.now();
    if (remainingMs <= 0) throw new Error('请求超时');
    return requestText(url, { ...options, timeoutMs: Math.max(100, Math.min(limitMs, remainingMs)) }, dispatcher);
  };
  try {
    if ((proxyPreferredUntil.get(origin) ?? 0) > Date.now()) {
      try {
        return await requestWithinDeadline(proxy);
      } catch {
        proxyPreferredUntil.delete(origin);
      }
    }
    try {
      const direct = await requestWithinDeadline(undefined, Math.min(DIRECT_PROBE_MAX_MS, Math.ceil(totalTimeoutMs * 0.45)));
      proxyPreferredUntil.delete(origin);
      return direct;
    } catch (directError) {
      if (deadline - Date.now() <= 100) throw directError;
      const proxied = await requestWithinDeadline(proxy);
      proxyPreferredUntil.set(origin, Date.now() + PROXY_PREFERENCE_TTL_MS);
      return proxied;
    }
  } finally {
    await proxy.close();
  }
}
