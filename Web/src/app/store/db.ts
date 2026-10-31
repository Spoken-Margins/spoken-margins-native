// The web app's own storage: IndexedDB in this browser, nothing on a server. Shows, episodes, Margins
// (voice audio included, as bytes: see voice-rows.ts), resume positions and settings. Every write is a single put or delete,
// so a closed tab never leaves half a change behind.
import type { Episode, Margin, PlaybackPosition, Show } from '../../shared/model.ts';
import { fromRow, toRow, type MarginRow } from './voice-rows.ts';
import { DB_VERSION, upgrade, type SettingRow, type Settings, type Snapshot } from './schema.ts';

const DB_NAME = 'spoken-margins';

export { DEFAULT_SETTINGS, type Settings, type Snapshot } from './schema.ts';

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
    request.onsuccess = () => {
      const db = request.result;
      // A newer copy of the app needs a new store: let it open rather than block it. This copy reopens on its
      // next write, and that write fails with a message rather than silently.
      db.onversionchange = () => {
        db.close();
        opening = undefined;
      };
      resolve(db);
    };
    request.onerror = () => {
      // Let the next write try again rather than fail forever on one bad open (a private window, a full disk).
      opening = undefined;
      reject(request.error);
    };
  });
  return opening;
}

function done(tx: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    // An aborted transaction can carry no error (a closed tab, a version change); still reject with one, so the
    // listener is told what wasn't saved rather than shown "null".
    tx.onerror = () => reject(tx.error ?? new DOMException('The write didn’t finish.', 'AbortError'));
    tx.onabort = () => reject(tx.error ?? new DOMException('The write didn’t finish.', 'AbortError'));
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
  const [shows, episodes, margins, positions, settings] = await Promise.all([
    all<Show>(db, 'shows'),
    all<Episode>(db, 'episodes'),
    all<MarginRow>(db, 'margins'),
    all<PlaybackPosition>(db, 'positions'),
    all<SettingRow>(db, 'settings'),
  ]);
  const upgraded = upgrade({ shows, episodes, margins: margins.map(fromRow), positions, settings });
  // Recording the shape is worth doing but not worth failing a load over: the rows read fine without it.
  if (upgraded.writes.length) await putMany('settings', upgraded.writes).catch(() => undefined);
  return upgraded.snapshot;
}

export async function putMany(store: StoreName, values: readonly object[]): Promise<void> {
  const db = await open();
  const tx = db.transaction(store, 'readwrite');
  const os = tx.objectStore(store);
  for (const value of values) os.put(value);
  await done(tx);
}

/** Saves a Margin. A voice Margin's audio goes in as bytes, since some browsers won't store a Blob (#3043). */
export async function putMargin(margin: Margin): Promise<void> {
  await putMany('margins', [await toRow(margin)]);
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

/** Writes a refreshed show and its new or changed episodes in one transaction (#2977). */
export async function putShowWithEpisodes(show: Show, episodes: readonly Episode[]): Promise<void> {
  const db = await open();
  const tx = db.transaction(['shows', 'episodes'], 'readwrite');
  tx.objectStore('shows').put(show);
  for (const episode of episodes) tx.objectStore('episodes').put(episode);
  await done(tx);
}

export async function putSetting<K extends keyof Settings>(key: K, value: Settings[K]): Promise<void> {
  await putMany('settings', [{ key, value }]);
}
