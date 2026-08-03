/// <reference types="vite/client" />

import type { LumenApi } from './types';

declare global {
  interface Window {
    lumen: LumenApi;
  }
}

export {};
