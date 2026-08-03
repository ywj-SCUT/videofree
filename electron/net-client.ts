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
  const proxy = new ProxyAgent(process.env.VIDEOGET_PROXY ?? 'http://127.0.0.1:7890');
  try {
    try {
      return await requestText(url, { ...options, timeoutMs: Math.min(options.timeoutMs ?? 12_000, 5_000) });
    } catch {
      return await requestText(url, options, proxy);
    }
  } finally {
    await proxy.close();
  }
}
