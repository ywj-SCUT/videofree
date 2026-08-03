import { NextResponse } from 'next/server';
import { aggregateDanmaku } from '../../../../electron/danmaku-engine';
import type { DanmakuProvider } from '../../../../src/types';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function POST(request: Request) {
  try {
    const body = await request.json() as { title?: string; episodeName?: string; providers?: DanmakuProvider[] };
    if (!body.title?.trim()) return NextResponse.json({ error: '缺少片名' }, { status: 400 });
    const providers = Array.isArray(body.providers) ? body.providers : [];
    return NextResponse.json(await aggregateDanmaku(providers, body.title.trim(), body.episodeName?.trim() || '第 1 集'));
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 502 });
  }
}
