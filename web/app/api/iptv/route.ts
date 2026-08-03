import { NextResponse } from 'next/server';
import { fetchIptvCatalog } from '../../../../electron/iptv-catalog';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function POST() {
  try {
    const lives = await fetchIptvCatalog();
    if (!lives.length) throw new Error('公开 IPTV 目录没有返回可用频道');
    return NextResponse.json({ sources: [], lives, failures: [] });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 502 });
  }
}
