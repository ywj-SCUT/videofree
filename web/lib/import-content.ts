import { importTvBox } from '../../electron/source-engine';
import type { CmsSource } from '../../electron/types';

export interface WebImportPayload {
  sources: CmsSource[];
  failures: string[];
}

function expandTvBox(config: unknown): WebImportPayload {
  const imported = importTvBox(config);
  return { sources: imported.sources, failures: [] };
}

export async function importWebContent(content: string, _name: string): Promise<WebImportPayload> {
  const trimmed = content.trim();
  if (!trimmed) throw new Error('导入内容为空');
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) return expandTvBox(JSON.parse(trimmed));

  throw new Error('仅支持 JSON 格式的 TVBox 点播配置');
}

export async function importWebTvBox(config: unknown): Promise<WebImportPayload> {
  return expandTvBox(config);
}
