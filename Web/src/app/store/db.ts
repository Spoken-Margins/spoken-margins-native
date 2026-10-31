// The web app's own storage: IndexedDB in this browser, nothing on a server. Shows, episodes, Margins
// (voice audio included, as Blobs), resume positions and settings. Every write is a single put or delete,
// so a closed tab never leaves half a change behind.
import type { Episode, Margin, PlaybackPosition, Show } from '../../shared/model.ts';

const DB_NAME = 'spoken-margins';
const DB_VERSION = 1;

export interface Settings {
  /** The listener allowed feeds a browser can't read to go through the Spoken Margins server. */
  relayAllowed: boolean;
  /** The relay pop-up has been answered once, either way. */
  relayAsked: boolean;
  playbackRate: number;
}

export const DEFAULT_SETTINGS: Settings = { relayAllowed: false, relayAsked: false, playbackRate: 1 };

export interface Snapshot {
  shows: Show[];
  episodes: Episode[];
  margins: Margin[];
  positions: PlaybackPosition[];
  settings: Settings;
}

type StoreName = 'shows' | 'episodes' | 'margins' | 'positions' | 'settings';

let opening: Promise<IDBDatabase> | undefined;

function open(): Promise<IDBDatabase> {
  opening ??= new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains('shows')) db.createObjectStore('shows', { keyPath: 'id' });
      if (!db.objectStoreNames.contains('episodes')) db.createObjectStore('episodes', { keyPath: 'id' }).createIndex('showId', 'showId');
      if (!db.objectStoreNames.contains('margins')) db.createObjectStore('margins', { keyPath: 'id' }).createIndex('episodeId', 'episodeId');
      if (!db.objectStoreNames.contains('positions')) db.createObjectStore('positions', { keyPath: 'episodeId' });
      if (!db.objectStoreNames.contains('settings')) db.createObjectStore('settings', { keyPath: 'key' });
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
  return opening;
}

function done(tx: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error);
  });
}

function all<T>(db: IDBDatabase, store: StoreName): Promise<T[]> {
  return new Promise((resolve, reject) => {
    const request = db.transaction(store).objectStore(store).getAll();
    request.onsuccess = () => resolve(request.result as T[]);
    request.onerror = () => reject(request.error);
  });
}

export async function loadAll(): Promise<Snapshot> {
  const db = await open();
  const [shows, episodes, margins, positions, settingRows] = await Promise.all([
    all<Show>(db, 'shows'),
    all<Episode>(db, 'episodes'),
    all<Margin>(db, 'margins'),
    all<PlaybackPosition>(db, 'positions'),
    all<{ key: string; value: unknown }>(db, 'settings'),
  ]);
  const settings: Settings = { ...DEFAULT_SETTINGS };
  for (const row of settingRows) {
    if (row.key in settings) (settings as unknown as Record<string, unknown>)[row.key] = row.value;
  }
  return { shows, episodes, margins, positions, settings };
}

export async function putMany(store: StoreName, values: readonly object[]): Promise<void> {
  const db = await open();
  const tx = db.transaction(store, 'readwrite');
  const os = tx.objectStore(store);
  for (const value of values) os.put(value);
  await done(tx);
}

export async function remove(store: StoreName, key: string): Promise<void> {
  const db = await open();
  const tx = db.transaction(store, 'readwrite');
  tx.objectStore(store).delete(key);
  await done(tx);
}

/** Removes a show and its episodes and positions in one transaction. Its Margins stay. */
export async function removeShow(showId: string, episodeIds: readonly string[]): Promise<void> {
  const db = await open();
  const tx = db.transaction(['shows', 'episodes', 'positions'], 'readwrite');
  tx.objectStore('shows').delete(showId);
  for (const id of episodeIds) {
    tx.objectStore('episodes').delete(id);
    tx.objectStore('positions').delete(id);
  }
  await done(tx);
}

export async function putSetting<K extends keyof Settings>(key: K, value: Settings[K]): Promise<void> {
  await putMany('settings', [{ key, value }]);
}
