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
import { browserStorage, forgetMirrored, mergeMirror, pruneMirror, readMirror } from './logic/position-mirror.ts';
import { addedRow, inLibrary, isMigrated, membershipRow, prepareLibrary, removedRow, restoredRow, stillMovedOut } from './logic/library-membership.ts';
import { mergeRefresh } from './logic/refresh.ts';
import { keepingSharedAs, withSharedAs, type WrittenFacts } from './logic/shared-as.ts';
import { keepingHeard, keepingStar, withStar } from './logic/star.ts';
import { FailureGate, NotSavedError, notSavedMessage, shouldAskToPersist, type PersistState, type WriteKind } from './logic/storage.ts';
import type { FeedRead } from './ports.ts';
import { DEFAULT_SETTINGS, loadAll, putMany, putMargin, putSetting, putShowWithEpisodes, remove, removeShow, type Settings, type Snapshot } from './store/db.ts';
import type { Membership } from './store/schema.ts';
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
  /**
   * Remembers, on each Margin a packet was just written from, the id that packet gives it (`sharedAs`, #4174). Built from
   * the Margins as stored now, so an edit made while the file was being written is kept and a Margin deleted meanwhile
   * stays deleted. Throws a `NotSavedError` when a write isn't kept.
   */
  addSharedAs(written: WrittenFacts): Promise<void>;
  /** Stars or unstars the listener's own Margin for sharing (#4172). Throws a `NotSavedError` when it isn't kept. */
  setStarred(marginId: string, on: boolean): Promise<void>;
  /** Marks a friend's Margin heard: the listener listened to some of it (part of #3216). Once heard, it stays heard. */
  setHeard(marginId: string): Promise<void>;
  deleteMargin(id: string): Promise<void>;
  savePosition(position: PlaybackPosition): Promise<void>;
  setSetting<K extends keyof Settings>(key: K, value: Settings[K]): Promise<void>;
  /** Whether the Library follows membership rows (the one-time move has run, #4425). False until then. */
  migrated: boolean;
  /**
   * Puts an episode in the Library (#4425): writes its "in" row, then updates the mirror at once, so a second call in
   * the same tick sees it. An episode already in is left alone (its first `at` stays). A failure is shown every
   * time (never a quiet repeat) and, without `quiet`, thrown as a `NotSavedError` so an Add button can reset. With
   * `quiet` (a play, an import) it is logged and returned, with no toast, since nobody waits on it.
   */
  addToLibrary(episodeId: string, options?: { quiet?: boolean }): Promise<void>;
  /**
   * Takes an episode out of the Library (#4424): writes an "out" row, then updates the mirror at once. Nothing else is
   * deleted. Returns the row it replaced (undefined if there was none), for `putBackInLibrary`. An episode already out
   * is left alone and its "out" row returned. Throws a `NotSavedError` when the write fails, and the row stays.
   */
  removeFromLibrary(episodeId: string): Promise<Membership | undefined>;
  /**
   * Undo for `removeFromLibrary`: writes `previous` back, unless the episode was added again meanwhile (that newer "in"
   * row stays). Throws a `NotSavedError` when the write fails.
   */
  putBackInLibrary(episodeId: string, previous: Membership | undefined): Promise<void>;
  /** The Library notice's Put them back: an "in" row for each moved-out episode still without a row. Returns how many. */
  putBackMovedOut(): Promise<number>;
  /** The Library notice's Got it: forgets the moved-out list. */
  dismissLibraryNotice(): Promise<void>;
}

const empty: Snapshot = { shows: [], episodes: [], margins: [], positions: [], settings: DEFAULT_SETTINGS, library: {} };
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
      .then(async (snapshot) => {
        // A place copied to localStorage that IndexedDB never got (the page went mid-write) wins if it is newer (#4096).
        const storage = browserStorage();
        const { positions, written } = mergeMirror(snapshot.positions, readMirror(storage), new Set(snapshot.episodes.map((e) => e.id)));
        // The one-time move, then the keep pass on every later load (#4425). `data` is set once, after it, so the Library
        // never flashes the old list or an empty state first.
        const merged: Snapshot = { ...snapshot, positions };
        const prepared = prepareLibrary({ ...merged }, new Date().toISOString());
        let loaded = merged;
        if (!isMigrated(snapshot.settings)) {
          try {
            // The rows and the moved-out list together, then `libraryModel` alone: a tab closed between the two runs the
            // move again, and the rows already written keep at least as much.
            await putMany('settings', prepared.rows);
            if (prepared.finish) await putMany('settings', [prepared.finish]);
            loaded = { ...merged, library: prepared.library, settings: { ...merged.settings, libraryMovedOut: prepared.movedOut, libraryModel: 'added' } };
          } catch (error) {
            // `libraryModel` stays unset, so the old rule holds for this session: the Library shows every episode.
            console.error('The Library move failed', error);
            toast('Your Library couldn’t be updated in this browser, so it shows every episode for now.', 'problem');
          }
        } else if (prepared.rows.length > 0) {
          try {
            await putMany('settings', prepared.rows);
          } catch (error) {
            console.error('The Library keep pass wasn’t saved', error); // Applied for this session; the next load tries again.
          }
          loaded = { ...merged, library: prepared.library };
        }
        setData(loaded);
        if (written.length > 0) void putMany('positions', written).then(() => pruneMirror(storage, positions), () => undefined);
        else pruneMirror(storage, positions);
      })
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
    async (kind: WriteKind, lead: string, write: () => Promise<void>, options: { quiet?: boolean } = {}): Promise<NotSavedError | undefined> => {
      try {
        await write();
        gate.current.worked(kind);
        return undefined;
      } catch (error) {
        const message = notSavedMessage(lead, error);
        console.error(message, error);
        // `quiet`: the listener isn't waiting on it (an episode that is already playing), so it is logged, not toasted.
        if (!options.quiet && gate.current.failed(kind)) toast(message, 'problem');
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
      forgetMirrored(browserStorage(), gone);
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

  /** Writes the Margin exactly as given. */
  const saveMargin = useCallback(
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

  // A rewrite of a Margin (its words, its reply link) is built from a copy that may be older than the star the listener
  // has since put on it, so the stored star is kept unless `setStarred` itself changes it (#4172).
  const addMargin = useCallback(
    (margin: Margin) => {
      const stored = dataRef.current.margins.find((m) => m.id === margin.id);
      return saveMargin(keepingHeard(keepingSharedAs(keepingStar(margin, stored), stored), stored));
    },
    [saveMargin],
  );

  const addSharedAs = useCallback(
    async (written: WrittenFacts) => {
      for (const margin of withSharedAs(written, dataRef.current.margins)) await saveMargin(margin);
    },
    [saveMargin],
  );

  const setStarred = useCallback(
    async (marginId: string, on: boolean) => {
      // Built from the Margin as stored now, so a star never undoes a reply change made a moment before.
      const stored = dataRef.current.margins.find((m) => m.id === marginId);
      // Always written, even when the stored star already agrees: a quick second tap reaches here before the first write lands.
      if (!stored) return;
      await saveMargin(withStar(stored, on));
    },
    [saveMargin],
  );

  const setHeard = useCallback(
    async (marginId: string) => {
      const stored = dataRef.current.margins.find((m) => m.id === marginId);
      if (!stored || stored.heard === true || !stored.author) return;
      await saveMargin({ ...stored, heard: true });
    },
    [saveMargin],
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

  const addToLibrary = useCallback(
    async (episodeId: string, options: { quiet?: boolean } = {}) => {
      const current = dataRef.current;
      if (inLibrary(episodeId, current.library)) return;
      const title = current.episodes.find((e) => e.id === episodeId)?.title ?? 'that episode';
      const row = addedRow(current.library[episodeId], new Date().toISOString());
      const failed = await run('library', `Adding “${title}” to your Library wasn’t saved.`, () => putMany('settings', [membershipRow(episodeId, row)]), { quiet: options.quiet });
      if (failed) {
        if (options.quiet) return;
        throw failed;
      }
      // Several adds can land one after another (an import, then a play): each must see the last without a render.
      const next = (d: Snapshot): Snapshot => ({ ...d, library: { ...d.library, [episodeId]: inLibrary(episodeId, d.library) ? d.library[episodeId]! : row } });
      setData(next);
      dataRef.current = next(dataRef.current);
    },
    [run],
  );

  const removeFromLibrary = useCallback(
    async (episodeId: string) => {
      const previous = dataRef.current.library[episodeId];
      if (previous && !previous.in) return previous;
      const title = dataRef.current.episodes.find((e) => e.id === episodeId)?.title ?? 'that episode';
      const row = removedRow(new Date().toISOString());
      const failed = await run('library', `Removing “${title}” from your Library wasn’t saved.`, () => putMany('settings', [membershipRow(episodeId, row)]));
      if (failed) throw failed;
      const next = (d: Snapshot): Snapshot => ({ ...d, library: { ...d.library, [episodeId]: row } });
      setData(next);
      dataRef.current = next(dataRef.current);
      return previous;
    },
    [run],
  );

  const putBackInLibrary = useCallback(
    async (episodeId: string, previous: Membership | undefined) => {
      const current = dataRef.current;
      const title = current.episodes.find((e) => e.id === episodeId)?.title ?? 'that episode';
      const now = new Date().toISOString();
      // With no earlier row the episode goes in as of now, the same as an Add.
      const row = restoredRow(current.library[episodeId], previous ?? { in: true, at: now });
      const failed = await run('library', `Putting “${title}” back in your Library wasn’t saved.`, () => putMany('settings', [membershipRow(episodeId, row)]));
      if (failed) throw failed;
      // Applied to the latest mirror, so a re-add that landed during the write is not undone.
      const next = (d: Snapshot): Snapshot => ({ ...d, library: { ...d.library, [episodeId]: restoredRow(d.library[episodeId], row) } });
      setData(next);
      dataRef.current = next(dataRef.current);
    },
    [run],
  );

  const putBackMovedOut = useCallback(async () => {
    const current = dataRef.current;
    const ids = stillMovedOut(current.settings.libraryMovedOut, current.episodes, current.library);
    const now = new Date().toISOString();
    const rows = [...ids.map((id) => membershipRow(id, { in: true, at: now })), { key: 'libraryMovedOut', value: [] as string[] }];
    const failed = await run('library', 'Your Library wasn’t updated.', () => putMany('settings', rows));
    if (failed) throw failed;
    const next = (d: Snapshot): Snapshot => {
      const library = { ...d.library };
      for (const id of ids) if (!Object.hasOwn(library, id)) library[id] = { in: true, at: now };
      return { ...d, library, settings: { ...d.settings, libraryMovedOut: [] } };
    };
    setData(next);
    dataRef.current = next(dataRef.current);
    return ids.length;
  }, [run]);

  const dismissLibraryNotice = useCallback(() => setSetting('libraryMovedOut', []), [setSetting]);

  const migrated = isMigrated(data.settings);

  const api = useMemo<DataApi>(
    () => ({ ...data, ready, persist, migrated, follow, unfollow, applyRefresh, updateEpisode, addMargin, addSharedAs, setStarred, setHeard, deleteMargin, savePosition, setSetting, addToLibrary, removeFromLibrary, putBackInLibrary, putBackMovedOut, dismissLibraryNotice }),
    [data, ready, persist, migrated, follow, unfollow, applyRefresh, updateEpisode, addMargin, addSharedAs, setStarred, setHeard, deleteMargin, savePosition, setSetting, addToLibrary, removeFromLibrary, putBackInLibrary, putBackMovedOut, dismissLibraryNotice],
  );
  return <DataContext.Provider value={api}>{children}</DataContext.Provider>;
}

export function useData(): DataApi {
  const api = useContext(DataContext);
  if (!api) throw new Error('useData outside DataProvider');
  return api;
}
