import { NextResponse } from 'next/server';
import { importWebContent, importWebTvBox } from '../../../lib/import-content';

export const runtime = 'nodejs';

export async function POST(request: Request) {
  try {
    const body = await request.json() as { config?: unknown; content?: string; name?: string };
    const imported = typeof body.content === 'string'
      ? await importWebContent(body.content, body.name ?? '导入文件')
      : await importWebTvBox(body.config);
    return NextResponse.json(imported);
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}
