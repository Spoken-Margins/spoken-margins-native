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
//    Later settings that default when missing (transcription, on-device speech-to-text) keep shape 2: an older copy
//    ignores a setting it doesn't know, and a newer one reads its default.
//    #3043: a voice Margin's audio is stored as bytes (`voice.data`) instead of a Blob (`voice.blob`), since Safari's
//    private browsing won't store a Blob. Rows with a Blob still read; see voice-rows.ts. Still shape 2.
//    Part of #3216: a Margin may carry `heard` and `leadIn`, and settings `marginAutoplay`; an older copy ignores all
//    three. Still shape 2.
//    #4425: Library membership. Settings `libraryModel` ('' or 'added') and `libraryMovedOut` (episode ids), plus one
//    row per episode the listener's Library holds or dropped, under the key `library:<episode id>` with the value
//    `{ in, at }`. All are settings rows that default when missing, so an older copy ignores them (`readSettings` skips
//    keys it doesn't know). Still shape 2: no record changed and no store was added.
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
  /**
   * On-device speech-to-text for voice Margins: '' until the listener has answered, then 'on' or 'off'. Nothing is
   * downloaded while it is not 'on'.
   */
  transcription: '' | 'on' | 'off';
  /**
   * The name the listener typed in the Share panel, for the packets they send. Optional and empty until typed; kept in
   * this browser and written only into a shared file (#4107). A backup never carries it.
   */
  senderName: string;
  /**
   * The Margins tab's Autoplay (part of #3216): which Margins play by themselves when the episode reaches them. 'unheard'
   * (friends' Margins not yet heard), 'all', or 'none' (a tone marks each). Defaults to 'unheard'.
   */
  marginAutoplay: 'unheard' | 'all' | 'none';
  /**
   * Which rule decides what the Library holds (#4425). '' (the default, and every store from before #4425): every
   * stored episode. 'added': only episodes whose membership row says in. Set once, after the one-time move has written
   * its rows, so a move cut short runs again.
   */
  libraryModel: '' | 'added';
  /**
   * Episode ids the one-time move left out of the Library (#4425), for the Library's notice and its Put them back.
   * Cleared by Got it. Anything that is not an array of strings reads as empty.
   */
  libraryMovedOut: readonly string[];
}

export const DEFAULT_SETTINGS: Settings = Object.freeze({
  relayAllowed: false,
  relayAsked: false,
  playbackRate: 1,
  persistAsked: false,
  lastBackupAt: '',
  transcription: '',
  senderName: '',
  marginAutoplay: 'unheard',
  libraryModel: '',
  libraryMovedOut: Object.freeze([]) as readonly string[],
});

/** The settings-store key prefix of a Library membership row (#4425): `library:<episode id>`. */
export const MEMBERSHIP_PREFIX = 'library:';

/**
 * Whether the listener's Library holds an episode (#4425). `in: false` is a removal (#4424), kept so a later pass never
 * adds the episode back on its own. `at` is when the row was first written, as an ISO date ('' when a stored row had
 * none).
 */
export interface Membership {
  in: boolean;
  at: string;
}

/** Membership rows by episode id. Episodes with no row are not in the Library once it is migrated. */
export type LibraryMembership = Readonly<Record<string, Membership>>;

export interface Snapshot {
  shows: Show[];
  episodes: Episode[];
  margins: Margin[];
  positions: PlaybackPosition[];
  settings: Settings;
  /** Library membership by episode id (#4425), read from the `library:` setting rows. */
  library: LibraryMembership;
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
    if (row.key === 'transcription' && !['', 'on', 'off'].includes(row.value as string)) continue;
    if (row.key === 'marginAutoplay' && !['unheard', 'all', 'none'].includes(row.value as string)) continue;
    if (row.key === 'libraryModel' && !['', 'added'].includes(row.value as string)) continue;
    if (row.key === 'libraryMovedOut') {
      if (!Array.isArray(row.value) || !row.value.every((id) => typeof id === 'string')) continue;
      target[row.key] = [...(row.value as string[])];
      continue;
    }
    target[row.key] = row.value;
  }
  return settings;
}

/**
 * Library membership from the `library:<episode id>` setting rows (#4425). A row whose value is not an object with a
 * boolean `in`, or whose key names no episode, is skipped. A missing or non-string `at` reads as ''. The result has no
 * prototype, so an episode id such as `constructor` can't read an inherited value.
 */
export function readMembership(rows: readonly SettingRow[]): LibraryMembership {
  const library: Record<string, Membership> = Object.create(null) as Record<string, Membership>;
  for (const row of rows) {
    if (typeof row.key !== 'string' || !row.key.startsWith(MEMBERSHIP_PREFIX)) continue;
    const id = row.key.slice(MEMBERSHIP_PREFIX.length);
    if (!id) continue;
    const value = row.value;
    if (typeof value !== 'object' || value === null || Array.isArray(value)) continue;
    const { in: isIn, at } = value as { in?: unknown; at?: unknown };
    if (typeof isIn !== 'boolean') continue;
    library[id] = { in: isIn, at: typeof at === 'string' ? at : '' };
  }
  return library;
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
    library: readMembership(rows.settings),
  };
  // 1 to 2 changed no record, only added the version row (and settings that default when missing).
  const writes = from < SCHEMA_VERSION ? [{ key: SCHEMA_KEY, value: SCHEMA_VERSION }] : [];
  return { snapshot, from, writes };
}
