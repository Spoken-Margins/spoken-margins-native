// Keeps followed shows current (#2977): reads their feeds when the app opens and whenever it comes back to the
// foreground, at most once per feed every 30 minutes, and on the Following tab's Refresh control. The rules (feeds
// only, the relay only with a standing yes, a few feeds at a time, merging without duplicates) are in
// logic/refresh.ts; this file only decides when to run and keeps what the Following tab shows.
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { useData } from './data.tsx';
import { dueShows, lastRefreshedAt, refreshResultLine, runRefresh, type RefreshOutcome } from './logic/refresh.ts';
import { NeedsRelayConsent } from './ports.ts';
import { RELAY_ORIGIN, services } from './services.ts';
import { useUi } from './ui.tsx';

export interface RefreshApi {
  /** A refresh is reading feeds now. */
  checking: boolean;
  /** The newest successful refresh of any followed show. */
  lastCheckedAt: string | undefined;
  /** Followed shows the last refresh skipped because they need the relay and the listener hasn't said yes. */
  needsRelay: number;
  /** Whether this build has a relay to say yes to. */
  relayAvailable: boolean;
  /** The Refresh control: reads every followed feed now and says what it found. */
  refresh(): Promise<void>;
  /** The consent action beside the skipped-shows line: asks once, then reads those feeds through the server. */
  allowRelay(): Promise<void>;
}

const RefreshContext = createContext<RefreshApi | null>(null);

type Trigger = 'auto' | 'listener';

export function FeedRefreshProvider({ children }: { children: ReactNode }) {
  const data = useData();
  const { toast, askRelay } = useUi();
  const [checking, setChecking] = useState(false);
  // The last outcome per show, so a run that reads only the due shows keeps the others' standing.
  const [status, setStatus] = useState<ReadonlyMap<string, RefreshOutcome['status']>>(new Map());
  const dataRef = useRef(data);
  dataRef.current = data;
  const attempts = useRef(new Map<string, number>());
  const running = useRef(false);

  const run = useCallback(
    async (trigger: Trigger, options: { only?: ReadonlySet<string>; relayAllowed?: boolean; force?: boolean } = {}) => {
      const current = dataRef.current;
      if (running.current || !current.ready) return;
      // Offline, every read fails the way a feed that needs the relay does; say nothing rather than the wrong thing.
      if (!navigator.onLine) {
        if (trigger === 'listener') toast('You’re offline. Connect to the internet to check for new episodes.');
        return;
      }
      const now = Date.now();
      const candidates = options.only ? current.shows.filter((s) => options.only?.has(s.id)) : current.shows;
      const shows = dueShows(candidates, attempts.current, now, { force: trigger === 'listener' || options.force === true });
      if (shows.length === 0) return;
      running.current = true;
      setChecking(true);
      for (const show of shows) attempts.current.set(show.id, now);
      let added = 0;
      try {
        const outcomes = await runRefresh({
          shows,
          relayAllowed: options.relayAllowed ?? current.settings.relayAllowed,
          needsRelay: (error) => error instanceof NeedsRelayConsent,
          readFeed: (feedUrl, read) => services.sources.readFeed(feedUrl, read),
          onOutcome: async (outcome) => {
            if (outcome.status === 'read') added += await dataRef.current.applyRefresh(outcome.showId, outcome.read);
            else if (outcome.status === 'failed') console.warn(`Refreshing ${outcome.showId} failed`, outcome.error);
          },
        });
        setStatus((previous) => {
          const next = new Map(previous);
          for (const outcome of outcomes) next.set(outcome.showId, outcome.status);
          return next;
        });
        // Feeds that were only skipped for the server get the line on the Following tab, not a toast as well.
        if (trigger === 'listener' && outcomes.some((o) => o.status !== 'needs-relay')) {
          toast(refreshResultLine(added, outcomes.filter((o) => o.status === 'failed').length));
        }
      } finally {
        running.current = false;
        setChecking(false);
      }
    },
    [toast],
  );

  // When the app opens (once the stored shows are loaded) and whenever it comes back to the foreground.
  useEffect(() => {
    if (data.ready) void run('auto');
  }, [data.ready, run]);
  useEffect(() => {
    const onVisible = () => {
      if (document.visibilityState === 'visible') void run('auto');
    };
    document.addEventListener('visibilitychange', onVisible);
    return () => document.removeEventListener('visibilitychange', onVisible);
  }, [run]);

  const refresh = useCallback(() => run('listener'), [run]);

  const skipped = useMemo(() => new Set([...status].filter(([, s]) => s === 'needs-relay').map(([id]) => id)), [status]);
  const skippedRef = useRef(skipped);
  skippedRef.current = skipped;

  const allowRelay = useCallback(async () => {
    if (!RELAY_ORIGIN) return;
    const yes = await askRelay();
    await dataRef.current.setSetting('relayAsked', true);
    await dataRef.current.setSetting('relayAllowed', yes);
    if (yes) await run('listener', { only: skippedRef.current, relayAllowed: true });
  }, [askRelay, run]);

  // A yes given elsewhere (Settings, or following a show that needed the server) reads the skipped feeds at once,
  // rather than 30 minutes later.
  const relayAllowed = data.settings.relayAllowed;
  useEffect(() => {
    if (relayAllowed && skippedRef.current.size > 0) void run('auto', { only: skippedRef.current, relayAllowed: true, force: true });
  }, [relayAllowed, run]);

  const followed = new Set(data.shows.map((s) => s.id));
  const needsRelay = relayAllowed ? 0 : [...skipped].filter((id) => followed.has(id)).length;
  const lastCheckedAt = lastRefreshedAt(data.shows);
  const api = useMemo<RefreshApi>(
    () => ({ checking, lastCheckedAt, needsRelay, relayAvailable: RELAY_ORIGIN !== '', refresh, allowRelay }),
    [checking, lastCheckedAt, needsRelay, refresh, allowRelay],
  );
  return <RefreshContext.Provider value={api}>{children}</RefreshContext.Provider>;
}

export function useFeedRefresh(): RefreshApi {
  const api = useContext(RefreshContext);
  if (!api) throw new Error('useFeedRefresh outside FeedRefreshProvider');
  return api;
}
