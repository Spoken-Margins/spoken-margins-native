// The web store's shape and how an older one is read (#3012). Plain TypeScript, so `npm run test:web` covers it
// (schema.test.ts) without a browser.
//
// Two version numbers, on purpose:
// - `DB_VERSION` is IndexedDB's own. It changes only when an object store or index is added, and stays 1 so a
//   copy of the web app still open in another tab, or cached by the service worker, keeps opening the database.
//   (An older copy asking for a lower version than the database has gets a VersionError and can't open it.)
// - `SCHEMA_VERSION` is ours, a row in the `settings` store. It says what the records look like. Readers fill
//   in anything an older shape lacks, and never rewrite or delete a record they don't understand, so a newer
//   copy's data survives an older copy and the other way round.
//
// Shapes:
// 1. #2989 to #3010: shows, episodes, margins, positions, settings {relayAllowed, relayAsked, playbackRate}.
//    No version row.
// 2. #3012: adds the version row and the settings persistAsked and lastBackupAt. Records are unchanged.
import type { Episode, Margin, PlaybackPosition, Show } from '../../shared/model.ts';

export const DB_VERSION = 1;
export const SCHEMA_VERSION = 2;
export const SCHEMA_KEY = 'schemaVersion';

export interface Settings {
  /** The listener allowed feeds a browser can't read to go through the Spoken Margins server. */
  relayAllowed: boolean;
  /** The relay pop-up has been answered once, either way. */
  relayAsked: boolean;
  playbackRate: number;
  /** The browser was asked once to keep this site's storage (after the first saved Margin). */
  persistAsked: boolean;
  /** When "Back up all Margins" last wrote a file, as an ISO date. Empty before the first backup. */
  lastBackupAt: string;
}

export const DEFAULT_SETTINGS: Settings = Object.freeze({
  relayAllowed: false,
  relayAsked: false,
  playbackRate: 1,
  persistAsked: false,
  lastBackupAt: '',
});

export interface Snapshot {
  shows: Show[];
  episodes: Episode[];
  margins: Margin[];
  positions: PlaybackPosition[];
  settings: Settings;
}

export interface SettingRow {
  key: string;
  value: unknown;
}

/** What the stores hold, read as they are. */
export interface StoredRows {
  shows: Show[];
  episodes: Episode[];
  margins: Margin[];
  positions: PlaybackPosition[];
  settings: SettingRow[];
}

export interface Upgraded {
  snapshot: Snapshot;
  /** The shape the rows were in. 1 when there is no version row. */
  from: number;
  /** Setting rows to write so the store records the current shape. Empty when nothing needs writing. */
  writes: SettingRow[];
}

/** The shape the stored rows are in: the version row, or 1 when there isn't one. */
export function storedVersion(rows: readonly SettingRow[]): number {
  const row = rows.find((r) => r.key === SCHEMA_KEY);
  return typeof row?.value === 'number' && Number.isInteger(row.value) && row.value >= 1 ? row.value : 1;
}

/** Settings from their rows: a known key with a value of the right type wins; anything else keeps its default. */
export function readSettings(rows: readonly SettingRow[]): Settings {
  const settings: Settings = { ...DEFAULT_SETTINGS };
  const target = settings as unknown as Record<string, unknown>;
  for (const row of rows) {
    if (!Object.hasOwn(DEFAULT_SETTINGS, row.key)) continue;
    if (typeof row.value !== typeof target[row.key]) continue;
    if (typeof row.value === 'number' && !Number.isFinite(row.value)) continue;
    target[row.key] = row.value;
  }
  return settings;
}

/**
 * Reads stored rows of any shape into the current one. Records pass through as they are, unknown fields
 * included, so a write back keeps what a newer copy added. A store from a newer copy is read the same way and
 * its version row is left alone.
 */
export function upgrade(rows: StoredRows): Upgraded {
  const from = storedVersion(rows.settings);
  const snapshot: Snapshot = {
    shows: rows.shows,
    episodes: rows.episodes,
    margins: rows.margins,
    positions: rows.positions,
    settings: readSettings(rows.settings),
  };
  // 1 to 2 changed no record, only added the version row (and settings that default when missing).
  const writes = from < SCHEMA_VERSION ? [{ key: SCHEMA_KEY, value: SCHEMA_VERSION }] : [];
  return { snapshot, from, writes };
}
