import { app } from 'electron';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import type { AppSettings, LibraryState } from './types.js';

interface PersistedData {
  settings: Omit<AppSettings, 'proxyPort'>;
  library: LibraryState;
}

const defaults: PersistedData = {
  settings: {
    sources: [],
    liveChannels: [],
    qualityPreference: 'highest',
  },
  library: { favorites: [], history: [] },
};

export class Storage {
  private data: PersistedData = structuredClone(defaults);
  private file = '';

  async init(): Promise<void> {
    const dir = path.join(app.getPath('userData'), 'data');
    await mkdir(dir, { recursive: true });
    this.file = path.join(dir, 'videoget.json');
    try {
      const raw = await readFile(this.file, 'utf8');
      const parsed = JSON.parse(raw) as Partial<PersistedData>;
      this.data = {
        settings: { ...defaults.settings, ...parsed.settings },
        library: { ...defaults.library, ...parsed.library },
      };
    } catch {
      await this.flush();
    }
  }

  getSettings(proxyPort: number): AppSettings {
    return { ...structuredClone(this.data.settings), proxyPort };
  }

  async updateSettings(settings: Partial<PersistedData['settings']>): Promise<void> {
    this.data.settings = { ...this.data.settings, ...structuredClone(settings) };
    await this.flush();
  }

  getLibrary(): LibraryState {
    return structuredClone(this.data.library);
  }

  async updateLibrary(library: LibraryState): Promise<void> {
    this.data.library = structuredClone(library);
    await this.flush();
  }

  private async flush(): Promise<void> {
    await writeFile(this.file, JSON.stringify(this.data, null, 2), 'utf8');
  }
}
