'use client';

import dynamic from 'next/dynamic';

const WebClient = dynamic(() => import('../components/WebClient'), { ssr: false });

export default function Page() {
  return <WebClient />;
}
