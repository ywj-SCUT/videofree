import { NextResponse } from 'next/server';
import { aggregateSearch } from '../../../../electron/source-engine';
import type { CmsSource, MediaCategory } from '../../../../electron/types';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function POST(request: Request) {
  try {
    const body = await request.json() as { query?: string; category?: MediaCategory; sources?: CmsSource[] };
    return NextResponse.json(await aggregateSearch(body.sources ?? [], body.query ?? '', body.category ?? 'all'));
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 500 });
  }
}
