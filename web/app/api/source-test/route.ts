import { NextResponse } from 'next/server';
import { testSource } from '../../../../electron/source-engine';
import type { CmsSource } from '../../../../electron/types';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function POST(request: Request) {
  try {
    const { source } = await request.json() as { source: CmsSource };
    return NextResponse.json(await testSource(source));
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 500 });
  }
}
