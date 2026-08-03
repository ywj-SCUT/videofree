import { NextResponse } from 'next/server';
import { resolveMedia } from '../../../../electron/source-engine';
import type { CmsSource, MediaItem } from '../../../../electron/types';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function POST(request: Request) {
  try {
    const body = await request.json() as { item: MediaItem; sources?: CmsSource[] };
    return NextResponse.json(await resolveMedia(body.sources ?? [], body.item));
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 500 });
  }
}
