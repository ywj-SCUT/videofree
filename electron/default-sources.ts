import type { CmsSource } from './types.js';

export const DEFAULT_SOURCES: CmsSource[] = [
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
];
