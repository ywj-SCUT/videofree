import type { LumenApi } from '../src/types';

declare global {
  interface Window {
    lumen: LumenApi;
  }
}

export {};
