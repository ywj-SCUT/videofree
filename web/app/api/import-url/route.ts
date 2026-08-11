import { NextResponse } from 'next/server';
import { fetchRemoteText } from '../../../../electron/net-client';
import { importWebContent } from '../../../lib/import-content';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function POST(request: Request) {
  try {
    const { url } = await request.json() as { url: string };
    if (!/^https?:\/\//i.test(url)) throw new Error('仅支持 HTTP/HTTPS 地址');
    const name = new URL(url).pathname.split('/').filter(Boolean).at(-1) ?? '远程导入';
    return NextResponse.json(await importWebContent(await fetchRemoteText(url), name));
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}
