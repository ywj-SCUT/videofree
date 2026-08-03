import { createHash } from 'node:crypto';
import { fetchRemoteText } from './net-client.js';
import type { LiveChannel } from './types.js';

const channelsUrl = 'https://iptv-org.github.io/api/channels.json';
const streamsUrl = 'https://iptv-org.github.io/api/streams.json';
const includedCountries = new Set(['CN', 'HK', 'MO', 'TW']);
const countryNames: Record<string, string> = { CN: '中国大陆', HK: '中国香港', MO: '中国澳门', TW: '中国台湾' };

interface CatalogChannel {
  id: string;
  name: string;
  country?: string;
  categories?: string[];
  logo?: string;
  is_nsfw?: boolean;
}

interface CatalogStream {
  channel?: string;
  url?: string;
}

function channelId(id: string): string {
  return `iptv-${createHash('sha1').update(id).digest('hex').slice(0, 16)}`;
}

export function buildIptvCatalog(channels: CatalogChannel[], streams: CatalogStream[]): LiveChannel[] {
  const metadata = new Map(channels
    .filter((channel) => channel.id && channel.name && includedCountries.has(channel.country ?? '') && !channel.is_nsfw)
    .map((channel) => [channel.id, channel]));
  const result = new Map<string, LiveChannel>();

  for (const stream of streams) {
    const channel = stream.channel ? metadata.get(stream.channel) : undefined;
    const url = stream.url?.trim() ?? '';
    if (!channel || !/^https?:\/\//i.test(url)) continue;
    const existing = result.get(channel.id);
    if (existing) {
      const urls = [...new Set([...(existing.urls ?? [existing.url]), url])];
      existing.urls = urls;
      existing.url = urls[0];
      continue;
    }
    const country = countryNames[channel.country ?? ''] ?? channel.country ?? '中文频道';
    const category = channel.categories?.[0] || '综合';
    result.set(channel.id, {
      id: channelId(channel.id), sourceId: 'iptv-org', sourceName: 'IPTV.org',
      tvgId: channel.id, name: channel.name, group: `${country} · ${category}`,
      logo: channel.logo || undefined, url, urls: [url],
    });
  }

  return [...result.values()].sort((left, right) => left.group.localeCompare(right.group, 'zh-CN') || left.name.localeCompare(right.name, 'zh-CN'));
}

export async function fetchIptvCatalog(): Promise<LiveChannel[]> {
  const [channelsText, streamsText] = await Promise.all([
    fetchRemoteText(channelsUrl, { timeoutMs: 30_000, maxBytes: 15 * 1024 * 1024 }),
    fetchRemoteText(streamsUrl, { timeoutMs: 30_000, maxBytes: 8 * 1024 * 1024 }),
  ]);
  return buildIptvCatalog(JSON.parse(channelsText) as CatalogChannel[], JSON.parse(streamsText) as CatalogStream[]);
}
