import { app } from 'electron';
import { copyFile, mkdir, readFile, rename, unlink, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { DEFAULT_SOURCES } from './default-sources.js';
import type { AppSettings, LibraryState } from './types.js';

interface PersistedData {
  playbackTuningVersion: number;
  managedSourcesVersion: number;
  settings: Omit<AppSettings, 'proxyPort'>;
  library: LibraryState;
}

const playbackTuningVersion = 2;
const managedSourcesVersion = 3;
const defaults: PersistedData = {
  playbackTuningVersion,
  managedSourcesVersion,
  settings: {
    sources: DEFAULT_SOURCES,
    danmakuProviders: [{ id: 'bilibili', name: 'Bilibili 弹幕', type: 'bilibili', enabled: true }],
    adFiltering: true,
    qualityPreference: 'auto',
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
    let parsed: Partial<PersistedData> | null = null;
    let restoredFromBackup = false;
    try {
      parsed = JSON.parse(await readFile(this.file, 'utf8')) as Partial<PersistedData>;
    } catch {
      try {
        parsed = JSON.parse(await readFile(`${this.file}.bak`, 'utf8')) as Partial<PersistedData>;
        restoredFromBackup = true;
      } catch {
        // First launch has no persisted state.
      }
    }
    if (parsed) {
      const needsPlaybackMigration = (parsed.playbackTuningVersion ?? 0) < playbackTuningVersion;
      const needsManagedSourcesMigration = (parsed.managedSourcesVersion ?? 0) < managedSourcesVersion;
      const persistedSources = parsed.settings?.sources ?? [];
      const persistedById = new Map(persistedSources.map((source) => [source.id, source]));
      const customSources = persistedSources.filter((source) => !source.id.startsWith('builtin-'));
      const managedSources = DEFAULT_SOURCES.map((source) => {
        const persisted = persistedById.get(source.id);
        return {
          ...source,
          enabled: persisted?.enabled ?? source.enabled,
          searchable: persisted?.searchable ?? source.searchable,
        };
      });
      const sources = persistedSources.length
        ? [...managedSources, ...customSources]
        : structuredClone(DEFAULT_SOURCES);
      this.data = {
        playbackTuningVersion,
        managedSourcesVersion,
        settings: {
          sources,
          danmakuProviders: parsed.settings?.danmakuProviders ?? structuredClone(defaults.settings.danmakuProviders),
          adFiltering: parsed.settings?.adFiltering ?? defaults.settings.adFiltering,
          qualityPreference: needsPlaybackMigration && parsed.settings?.qualityPreference === 'highest'
            ? 'auto'
            : parsed.settings?.qualityPreference ?? defaults.settings.qualityPreference,
        },
        library: { ...defaults.library, ...parsed.library },
      };
      if (needsPlaybackMigration || needsManagedSourcesMigration || restoredFromBackup) {
        await this.flush(!restoredFromBackup);
      }
    } else {
      await this.flush(false);
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

  private async flush(backupCurrent = true): Promise<void> {
    const temporary = `${this.file}.tmp`;
    const backup = `${this.file}.bak`;
    await writeFile(temporary, JSON.stringify(this.data, null, 2), 'utf8');
    if (backupCurrent) {
      try { await copyFile(this.file, backup); } catch {}
    }
    try {
      await rename(temporary, this.file);
    } catch (error) {
      try { await unlink(temporary); } catch {}
      throw error;
    }
  }
}
