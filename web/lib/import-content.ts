import { parseLivePlaylist } from '../../electron/live-engine';
import { fetchRemoteText } from '../../electron/net-client';
import { importTvBox } from '../../electron/source-engine';
import type { CmsSource, LiveChannel } from '../../electron/types';

export interface WebImportPayload {
  sources: CmsSource[];
  lives: LiveChannel[];
  failures: string[];
}

async function expandTvBox(config: unknown): Promise<WebImportPayload> {
  const imported = importTvBox(config);
  const lives = [...imported.lives];
  const failures: string[] = [];

  for (const playlist of imported.livePlaylists) {
    try {
      const channels = parseLivePlaylist(await fetchRemoteText(playlist.url), playlist.id, playlist.name);
      if (channels.length) lives.push(...channels);
      else if (/\.m3u8(?:$|\?)/i.test(playlist.url)) {
        lives.push({
          id: `${playlist.id}-direct`, sourceId: playlist.id, sourceName: playlist.name,
          name: playlist.name, group: playlist.name, url: playlist.url, urls: [playlist.url],
        });
      } else failures.push(`${playlist.name}: 播放列表中没有频道`);
    } catch (error) {
      failures.push(`${playlist.name}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  return { sources: imported.sources, lives, failures };
}

export async function importWebContent(content: string, name: string, originUrl?: string): Promise<WebImportPayload> {
  const trimmed = content.trim();
  if (!trimmed) throw new Error('导入内容为空');
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) return expandTvBox(JSON.parse(trimmed));

  const sourceName = name || '导入直播';
  const sourceId = `playlist-${Buffer.from(sourceName).toString('base64url').slice(0, 32) || Date.now()}`;
  let lives = parseLivePlaylist(trimmed, sourceId, sourceName);
  if (!lives.length && originUrl && /\.m3u8(?:$|\?)/i.test(originUrl)) {
    lives = [{
      id: `${sourceId}-direct`, sourceId, sourceName,
      name: sourceName, group: sourceName, url: originUrl, urls: [originUrl],
    }];
  }
  if (!lives.length) throw new Error('未识别到 TVBox 配置或直播频道');
  return { sources: [], lives, failures: [] };
}

export async function importWebTvBox(config: unknown): Promise<WebImportPayload> {
  return expandTvBox(config);
}
