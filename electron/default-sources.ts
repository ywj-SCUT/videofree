import type { CmsSource } from './types.js';

export const DEFAULT_SOURCES: CmsSource[] = [
  {
    id: 'builtin-short-tikhub-tiktok', name: 'TikTok 推荐', type: 'short-api',
    api: 'https://api.tikhub.io', provider: 'tikhub-tiktok', region: 'US',
    enabled: false, searchable: true,
  },
  {
    id: 'builtin-short-douyin', name: '抖音推荐', type: 'short-api',
    api: 'https://api.tikhub.io', provider: 'tikhub-douyin', region: 'CN',
    enabled: false, searchable: true,
  },
  {
    id: 'builtin-short-youtube', name: 'YouTube Shorts', type: 'short-api',
    api: 'https://api.tikhub.io', provider: 'tikhub-youtube', region: 'CN',
    enabled: false, searchable: true,
  },
  {
    id: 'builtin-line-a', name: '默认线路 A', type: 'cms',
    api: 'https://caiji.moduapi.cc/api.php/provide/vod/',
    enabled: true, searchable: true,
  },
  {
    id: 'builtin-line-b', name: '默认线路 B', type: 'cms',
    api: 'https://jszyapi.com/api.php/provide/vod/',
    enabled: true, searchable: true,
  },
  {
    id: 'builtin-line-c', name: '默认线路 C', type: 'cms',
    api: 'https://cj.lziapi.com/api.php/provide/vod/',
    enabled: true, searchable: true,
  },
  {
    id: 'builtin-line-d', name: '默认线路 D', type: 'cms',
    api: 'https://api.ukuapi.com/api.php/provide/vod/',
    enabled: true, searchable: true,
  },
  {
    id: 'builtin-line-e', name: '默认线路 E', type: 'cms',
    api: 'https://api.wujinapi.com/api.php/provide/vod/',
    enabled: true, searchable: true,
  },
  {
    id: 'builtin-line-f', name: '默认线路 F', type: 'cms',
    api: 'https://cj.rycjapi.com/api.php/provide/vod/',
    enabled: true, searchable: true,
  },
  {
    id: 'builtin-line-g', name: '默认线路 G', type: 'cms',
    api: 'https://cj.ffzyapi.com/api.php/provide/vod/',
    enabled: true, searchable: true,
  },
  {
    id: 'builtin-line-h', name: '默认线路 H', type: 'cms',
    api: 'https://bfzyapi.com/api.php/provide/vod/',
    enabled: true, searchable: true,
  },
];
