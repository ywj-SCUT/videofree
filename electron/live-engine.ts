import { createHash } from 'node:crypto';
import type { LiveChannel } from './types.js';

function stableId(sourceId: string, group: string, name: string): string {
  return `live-${createHash('sha1').update(`${sourceId}\n${group}\n${name}`).digest('hex').slice(0, 16)}`;
}

function attributes(line: string): Record<string, string> {
  const result: Record<string, string> = {};
  for (const match of line.matchAll(/([\w-]+)="([^"]*)"/g)) result[match[1].toLowerCase()] = match[2];
  return result;
}

function validStreamUrls(value: string): string[] {
  return value
    .split(/#(?=https?:\/\/)/i)
    .map((entry) => entry.trim().replace(/^#/, ''))
    .filter((entry) => /^https?:\/\//i.test(entry));
}

function addChannel(channels: LiveChannel[], channel: LiveChannel): void {
  const existing = channels.find((entry) => entry.group === channel.group && entry.name === channel.name);
  if (!existing) {
    channels.push(channel);
    return;
  }
  const urls = [...new Set([...(existing.urls ?? [existing.url]), ...(channel.urls ?? [channel.url])])];
  existing.urls = urls;
  existing.url = urls[0];
  if (!existing.logo && channel.logo) existing.logo = channel.logo;
  if (!existing.tvgId && channel.tvgId) existing.tvgId = channel.tvgId;
}

export function parseLivePlaylist(content: string, sourceId: string, sourceName: string): LiveChannel[] {
  const lines = content.replace(/^\uFEFF/, '').split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  const channels: LiveChannel[] = [];
  let group = sourceName || '未分组';

  for (let index = 0; index < lines.length; index++) {
    const line = lines[index];
    if (line.startsWith('#EXTINF:')) {
      const attrs = attributes(line);
      const commaAt = line.lastIndexOf(',');
      const name = (commaAt >= 0 ? line.slice(commaAt + 1) : attrs['tvg-name']).trim();
      const next = lines[index + 1];
      const urls = next && !next.startsWith('#') ? validStreamUrls(next) : [];
      if (name && urls.length) {
        const channelGroup = attrs['group-title'] || group;
        addChannel(channels, {
          id: stableId(sourceId, channelGroup, name), sourceId, sourceName,
          tvgId: attrs['tvg-id'], name, group: channelGroup, logo: attrs['tvg-logo'],
          url: urls[0], urls,
        });
        index++;
      }
      continue;
    }
    if (line.startsWith('#')) continue;
    const commaAt = line.indexOf(',');
    if (commaAt < 0) continue;
    const name = line.slice(0, commaAt).trim();
    const value = line.slice(commaAt + 1).trim();
    if (/^#genre#$/i.test(value)) {
      group = name || group;
      continue;
    }
    const urls = validStreamUrls(value);
    if (!name || !urls.length) continue;
    addChannel(channels, {
      id: stableId(sourceId, group, name), sourceId, sourceName,
      name, group, url: urls[0], urls,
    });
  }
  return channels;
}

export function mergeLiveChannels(existing: LiveChannel[], incoming: LiveChannel[]): LiveChannel[] {
  const merged = existing.map((channel) => structuredClone(channel));
  incoming.forEach((channel) => addChannel(merged, structuredClone(channel)));
  return merged;
}
