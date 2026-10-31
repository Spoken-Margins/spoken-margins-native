// App-wide data: everything in IndexedDB, mirrored in memory for rendering. Writes go to IndexedDB first
// and then update the mirror, so what the screen shows is what a reload will show.
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import type { Episode, Margin, PlaybackPosition, Show } from '../shared/model.ts';
import { DEFAULT_SETTINGS, loadAll, putMany, putSetting, remove, removeShow, type Settings, type Snapshot } from './store/db.ts';

export interface DataApi extends Snapshot {
  ready: boolean;
  follow(show: Show, episodes: Episode[]): Promise<void>;
  unfollow(showId: string): Promise<void>;
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

export function DataProvider({ children }: { children: ReactNode }) {
  const [data, setData] = useState<Snapshot>(empty);
  const [ready, setReady] = useState(false);
  const dataRef = useRef(data);
  dataRef.current = data;

  useEffect(() => {
    loadAll()
      .then((snapshot) => setData(snapshot))
      .catch((error: unknown) => console.error('Could not open storage', error))
      .finally(() => setReady(true));
  }, []);

  const follow = useCallback(async (show: Show, episodes: Episode[]) => {
    await putMany('shows', [show]);
    await putMany('episodes', episodes);
    setData((d) => ({ ...d, shows: upsert(d.shows, [show], (s) => s.id), episodes: upsert(d.episodes, episodes, (e) => e.id) }));
  }, []);

  const unfollow = useCallback(async (showId: string) => {
    // Episodes that carry Margins stay, so the Margins tab can still name them.
    const current = dataRef.current;
    const withMargins = new Set(current.margins.map((m) => m.episodeId));
    const doomed = current.episodes.filter((e) => e.showId === showId && !withMargins.has(e.id)).map((e) => e.id);
    await removeShow(showId, doomed);
    const gone = new Set(doomed);
    setData((d) => ({
      ...d,
      shows: d.shows.filter((s) => s.id !== showId),
      episodes: d.episodes.filter((e) => !gone.has(e.id)),
      positions: d.positions.filter((p) => !gone.has(p.episodeId)),
    }));
  }, []);

  const updateEpisode = useCallback(async (episode: Episode) => {
    await putMany('episodes', [episode]);
    setData((d) => ({ ...d, episodes: upsert(d.episodes, [episode], (e) => e.id) }));
  }, []);

  const addMargin = useCallback(async (margin: Margin) => {
    await putMany('margins', [margin]);
    setData((d) => ({ ...d, margins: upsert(d.margins, [margin], (m) => m.id) }));
  }, []);

  const deleteMargin = useCallback(async (id: string) => {
    await remove('margins', id);
    setData((d) => ({ ...d, margins: d.margins.filter((m) => m.id !== id) }));
  }, []);

  const savePosition = useCallback(async (position: PlaybackPosition) => {
    await putMany('positions', [position]);
    setData((d) => ({ ...d, positions: upsert(d.positions, [position], (p) => p.episodeId) }));
  }, []);

  const setSetting = useCallback(async <K extends keyof Settings>(key: K, value: Settings[K]) => {
    await putSetting(key, value);
    setData((d) => ({ ...d, settings: { ...d.settings, [key]: value } }));
  }, []);

  const api = useMemo<DataApi>(
    () => ({ ...data, ready, follow, unfollow, updateEpisode, addMargin, deleteMargin, savePosition, setSetting }),
    [data, ready, follow, unfollow, updateEpisode, addMargin, deleteMargin, savePosition, setSetting],
  );
  return <DataContext.Provider value={api}>{children}</DataContext.Provider>;
}

export function useData(): DataApi {
  const api = useContext(DataContext);
  if (!api) throw new Error('useData outside DataProvider');
  return api;
}
