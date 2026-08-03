import type { Metadata } from 'next';
import '../../src/styles.css';

export const metadata: Metadata = {
  title: 'VideoGET',
  description: '多源聚合视频搜索与高清播放',
  icons: { icon: '/videoget-icon.png' },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="zh-CN"><body>{children}</body></html>;
}
