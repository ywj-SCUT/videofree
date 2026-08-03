import { NextResponse } from 'next/server';
import { getDetail } from '../../../../electron/source-engine';
import type { CmsSource } from '../../../../electron/types';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function POST(request: Request) {
  try {
    const body = await request.json() as { sourceId: string; id: string; sources?: CmsSource[] };
    return NextResponse.json(await getDetail(body.sources ?? [], body.sourceId, body.id));
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 500 });
  }
}
