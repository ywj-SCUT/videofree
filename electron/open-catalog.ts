import type { MediaItem } from './types.js';

const hlsDemo = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';

export const OPEN_CATALOG: MediaItem[] = [
  {
    id: 'open-big-buck-bunny', sourceId: 'open-cinema', sourceName: '开放影院',
    title: 'Big Buck Bunny', poster: './posters/big-buck-bunny.jpg', backdrop: './posters/big-buck-bunny-hero.jpg',
    year: '2008', remarks: '开放动画短片', category: 'anime', quality: '1080P',
    summary: 'Blender Foundation 制作并以开放许可发布的动画短片。',
    playLines: [{ name: '自适应高清', episodes: [{ name: '正片', url: hlsDemo }] }],
  },
  {
    id: 'open-sintel', sourceId: 'open-cinema', sourceName: '开放影院',
    title: 'Sintel', poster: './posters/sintel.jpg',
    year: '2010', remarks: '开放动画电影', category: 'movie', quality: '1080P',
    summary: '一位年轻女孩寻找小龙伙伴的奇幻旅程。Blender Foundation 开放电影。',
    playLines: [{ name: '高清', episodes: [{ name: '正片', url: 'https://archive.org/download/Sintel/sintel-2048-stereo.mp4' }] }],
  },
  {
    id: 'open-tears-of-steel', sourceId: 'open-cinema', sourceName: '开放影院',
    title: 'Tears of Steel', poster: './posters/tears-of-steel.jpg',
    year: '2012', remarks: '科幻短片', category: 'short', quality: '1080P',
    summary: '真人与视觉特效结合的开放科幻短片。',
    playLines: [{ name: '高清', episodes: [{ name: '正片', url: 'https://archive.org/download/Tears-of-Steel/tears_of_steel_1080p.mp4' }] }],
  },
  {
    id: 'open-elephants-dream', sourceId: 'open-cinema', sourceName: '开放影院',
    title: 'Elephants Dream', poster: './posters/elephants-dream.jpg',
    year: '2006', remarks: '开放动画电影', category: 'movie', quality: '1080P',
    summary: 'Blender Foundation 的第一部开放电影。',
    playLines: [{ name: '高清', episodes: [{ name: '正片', url: 'https://archive.org/download/ElephantsDream/ed_hd.mp4' }] }],
  },
  {
    id: 'open-for-bigger-blazes', sourceId: 'open-cinema', sourceName: '开放影院',
    title: 'AI 影像工作流演示', poster: './posters/ai-short-demo.jpg',
    year: '2025', remarks: 'AI短剧工作流示例', category: 'ai-short', quality: '1080P',
    summary: '用于验证 AI 短剧分类、竖屏模式和播放链路的开放演示素材。',
    playLines: [{ name: '演示', episodes: [{ name: '第 1 集', url: 'https://archive.org/download/springopenmovie/springopenmovie.mp4' }] }],
  },
];
