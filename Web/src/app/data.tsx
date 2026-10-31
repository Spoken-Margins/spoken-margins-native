// App-wide data: everything in IndexedDB, mirrored in memory for rendering. Writes go to IndexedDB first
// and then update the mirror, so what the screen shows is what a reload will show.
//
// No write fails silently (#3012). Each one that fails shows a problem naming what wasn't saved, and the mirror
// keeps showing what is really stored. Writes the listener asked for (a Margin, a follow) then throw a
// `NotSavedError`, so the caller can keep its composer open; the app's own background writes (your place, a
// setting) don't throw, since nobody waits on them.
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { formatClock } from '../shared/clock.ts';
import type { Episode, Margin, PlaybackPosition, Show } from '../shared/model.ts';
import { mergeRefresh } from './logic/refresh.ts';
import { FailureGate, NotSavedError, notSavedMessage, shouldAskToPersist, type PersistState, type WriteKind } from './logic/storage.ts';
import type { FeedRead } from './ports.ts';
import { DEFAULT_SETTINGS, loadAll, putMany, putMargin, putSetting, putShowWithEpisodes, remove, removeShow, type Settings, type Snapshot } from './store/db.ts';
import { useUi } from './ui.tsx';

export interface DataApi extends Snapshot {
  ready: boolean;
  /** Whether the browser has agreed to keep this site's storage when space runs low. */
  persist: PersistState;
  follow(show: Show, episodes: Episode[]): Promise<void>;
  unfollow(showId: string): Promise<void>;
  /**
   * Merges a fresh read of a followed show's feed into what is stored (logic/refresh.ts) and returns how many
   * episodes are new. A show unfollowed while its feed was being read is left unfollowed (0).
   */
  applyRefresh(showId: string, read: FeedRead): Promise<number>;
  updateEpisode(episode: Episode): Promise<void>;
  addMargin(margin: Margin): Promise<void>;
  deleteMargin(id: string): Promise<void>;
  savePosition(position: PlaybackPosition): Promise<void>;
  setSetting<K extends keyof Settings>(key: K, value: Settings[K]): Promise<void>;
}

const empty: Snapshot = { shows: [], episodes: [], margins: [], positions: [], settings: DEFAULT_SETTINGS };
const DataContext = createContext<DataApi | null>(null);

function upsert<T>(list: T[], items: readonly T[], key: (t: T) => string): T[] {
  const incoming = new Map(items.map((i) => [key(i), i]));
  const kept = list.filter((i) => !incoming.has(key(i)));
  return [...kept, ...items];
}

/** The browser's StorageManager, where it has one with persist(). */
function storageManager(): StorageManager | undefined {
  const manager = typeof navigator === 'undefined' ? undefined : navigator.storage;
  return manager && typeof manager.persist === 'function' && typeof manager.persisted === 'function' ? manager : undefined;
}

export function DataProvider({ children }: { children: ReactNode }) {
  const { toast } = useUi();
  const [data, setData] = useState<Snapshot>(empty);
  const [ready, setReady] = useState(false);
  const [persist, setPersist] = useState<PersistState>('unknown');
  const dataRef = useRef(data);
  dataRef.current = data;
  const persistRef = useRef(persist);
  persistRef.current = persist;
  const gate = useRef(new FailureGate());
  const asking = useRef(false);

  useEffect(() => {
    loadAll()
      .then((snapshot) => setData(snapshot))
      .catch((error: unknown) => {
        console.error('Could not open storage', error);
        toast(notSavedMessage('Your saved shows and Margins couldn’t be opened in this browser.', error), 'problem');
      })
      .finally(() => setReady(true));
    // Only reads the state; asking (which may prompt) waits for the first saved Margin.
    const manager = storageManager();
    if (!manager) setPersist('unsupported');
    else void manager.persisted().then((kept) => setPersist(kept ? 'kept' : 'not-kept'), () => setPersist('not-kept'));
  }, [toast]);

  /** Runs a write. On failure, shows `lead` and the reason, and returns the error to throw (or not). */
  const run = useCallback(
    async (kind: WriteKind, lead: string, write: () => Promise<void>): Promise<NotSavedError | undefined> => {
      try {
        await write();
        gate.current.worked(kind);
        return undefined;
      } catch (error) {
        const message = notSavedMessage(lead, error);
        console.error(message, error);
        if (gate.current.failed(kind)) toast(message, 'problem');
        return new NotSavedError(message, { cause: error });
      }
    },
    [toast],
  );

  const setSetting = useCallback(
    async <K extends keyof Settings>(key: K, value: Settings[K]) => {
      const failed = await run('setting', 'A setting wasn’t saved.', () => putSetting(key, value));
      if (!failed) setData((d) => ({ ...d, settings: { ...d.settings, [key]: value } }));
    },
    [run],
  );

  /** After a Margin is saved, asks the browser once to keep this site's storage. Never on load. */
  const askToPersist = useCallback(async () => {
    const manager = storageManager();
    const current = dataRef.current;
    if (!manager || asking.current || !shouldAskToPersist(persistRef.current, current.settings.persistAsked, current.margins.length)) return;
    asking.current = true;
    try {
      const kept = await manager.persist().catch(() => false);
      setPersist(kept ? 'kept' : 'not-kept');
      await setSetting('persistAsked', true);
    } finally {
      asking.current = false;
    }
  }, [setSetting]);

  const follow = useCallback(
    async (show: Show, episodes: Episode[]) => {
      const failed = await run('follow', `Following ${show.title} wasn’t saved.`, async () => {
        await putMany('shows', [show]);
        await putMany('episodes', episodes);
      });
      if (failed) throw failed;
      setData((d) => ({ ...d, shows: upsert(d.shows, [show], (s) => s.id), episodes: upsert(d.episodes, episodes, (e) => e.id) }));
    },
    [run],
  );

  const unfollow = useCallback(
    async (showId: string) => {
      // Episodes that carry Margins stay, so the Margins tab can still name them.
      const current = dataRef.current;
      const title = current.shows.find((s) => s.id === showId)?.title ?? 'that show';
      const withMargins = new Set(current.margins.map((m) => m.episodeId));
      const doomed = current.episodes.filter((e) => e.showId === showId && !withMargins.has(e.id)).map((e) => e.id);
      const failed = await run('unfollow', `Unfollowing ${title} wasn’t saved.`, () => removeShow(showId, doomed));
      if (failed) throw failed;
      const gone = new Set(doomed);
      setData((d) => ({
        ...d,
        shows: d.shows.filter((s) => s.id !== showId),
        episodes: d.episodes.filter((e) => !gone.has(e.id)),
        positions: d.positions.filter((p) => !gone.has(p.episodeId)),
      }));
    },
    [run],
  );

  const applyRefresh = useCallback(
    async (showId: string, read: FeedRead) => {
      // Merged against what is stored now, not when the read began: a post tapped meanwhile keeps its voice.
      const current = dataRef.current;
      const stored = current.shows.find((s) => s.id === showId);
      if (!stored) return 0;
      const merged = mergeRefresh({ show: stored, episodes: current.episodes.filter((e) => e.showId === showId) }, read, new Date().toISOString());
      const failed = await run('refresh', `New episodes of ${stored.title} weren’t saved.`, () => putShowWithEpisodes(merged.show, merged.write));
      if (failed) throw failed;
      const next = (d: Snapshot): Snapshot =>
        d.shows.some((s) => s.id === showId)
          ? { ...d, shows: upsert(d.shows, [merged.show], (s) => s.id), episodes: upsert(d.episodes, merged.write, (e) => e.id) }
          : d;
      setData(next);
      // Feeds finish one after another; the next merge must see this one without waiting for a render.
      dataRef.current = next(dataRef.current);
      return merged.added;
    },
    [run],
  );

  const updateEpisode = useCallback(
    async (episode: Episode) => {
      const failed = await run('episode', `“${episode.title}” wasn’t saved.`, () => putMany('episodes', [episode]));
      if (failed) throw failed;
      setData((d) => ({ ...d, episodes: upsert(d.episodes, [episode], (e) => e.id) }));
    },
    [run],
  );

  const addMargin = useCallback(
    async (margin: Margin) => {
      const what = margin.voice ? 'voice Margin' : 'Margin';
      const lead = margin.author ? `A ${what} at ${formatClock(margin.atSeconds)} wasn’t saved.` : `Your ${what} at ${formatClock(margin.atSeconds)} wasn’t saved.`;
      const failed = await run('margin', lead, () => putMargin(margin));
      if (failed) throw failed;
      setData((d) => ({ ...d, margins: upsert(d.margins, [margin], (m) => m.id) }));
      dataRef.current = { ...dataRef.current, margins: upsert(dataRef.current.margins, [margin], (m) => m.id) };
      void askToPersist();
    },
    [run, askToPersist],
  );

  const deleteMargin = useCallback(
    async (id: string) => {
      const failed = await run('delete-margin', 'That Margin wasn’t deleted.', () => remove('margins', id));
      if (failed) throw failed;
      setData((d) => ({ ...d, margins: d.margins.filter((m) => m.id !== id) }));
    },
    [run],
  );

  const savePosition = useCallback(
    async (position: PlaybackPosition) => {
      const title = dataRef.current.episodes.find((e) => e.id === position.episodeId)?.title;
      const lead = `Your place${title ? ` in “${title}”` : ''} wasn’t saved.`;
      const failed = await run('position', lead, () => putMany('positions', [position]));
      if (!failed) setData((d) => ({ ...d, positions: upsert(d.positions, [position], (p) => p.episodeId) }));
    },
    [run],
  );

  const api = useMemo<DataApi>(
    () => ({ ...data, ready, persist, follow, unfollow, applyRefresh, updateEpisode, addMargin, deleteMargin, savePosition, setSetting }),
    [data, ready, persist, follow, unfollow, applyRefresh, updateEpisode, addMargin, deleteMargin, savePosition, setSetting],
  );
  return <DataContext.Provider value={api}>{children}</DataContext.Provider>;
}

export function useData(): DataApi {
  const api = useContext(DataContext);
  if (!api) throw new Error('useData outside DataProvider');
  return api;
}
