import { useCallback, useEffect, useRef, useState, type FormEvent } from 'react';
import { useRestoreFocus } from '../focus.ts';
import type { Show } from '../../shared/model.ts';
import { useData } from '../data.tsx';
import { minutes, shortDate } from '../format.ts';
import { ChevronIcon, CloseIcon, PlayIcon, PlusIcon, RefreshIcon } from '../icons.tsx';
import { followingRows, libraryRows, newestFirst } from '../logic/library.ts';
import { plainError } from '../logic/messages.ts';
import { checkedLabel, needsRelayLine } from '../logic/refresh.ts';
import { suggestionsToShow } from '../logic/suggestions.ts';
import { usePlayer } from '../player.tsx';
import { useFeedRefresh } from '../refresh.tsx';
import { services } from '../services.ts';
import { useRelay, useUi } from '../ui.tsx';
import { StateTag } from './Library.tsx';

export function Following({ onPlay, followOpen, setFollowOpen }: { onPlay: () => void; followOpen: boolean; setFollowOpen: (open: boolean) => void }) {
  const data = useData();
  const player = usePlayer();
  const [openShowId, setOpenShowId] = useState<string>();
  // The show the listener came back from, so focus lands on its row again, not at the top of the page.
  const [returnTo, setReturnTo] = useState<string>();
  const refresh = useFeedRefresh();
  const rows = followingRows(data.shows, data.episodes, data.positions);
  const openShow = data.shows.find((s) => s.id === openShowId);

  useEffect(() => {
    if (openShowId || !returnTo) return;
    const row = document.querySelector<HTMLElement>(`[data-show-id="${CSS.escape(returnTo)}"]`);
    (row ?? document.getElementById('following-title'))?.focus();
    setReturnTo(undefined);
  }, [openShowId, returnTo]);

  if (openShow) {
    return (
      <ShowScreen
        show={openShow}
        onBack={() => {
          setReturnTo(openShow.id);
          setOpenShowId(undefined);
        }}
        onPlay={onPlay}
      />
    );
  }

  return (
    <div className="screen">
      <header className="screen-header">
        <h1 id="following-title" tabIndex={-1}>
          Following
        </h1>
        <div className="header-actions">
          {rows.length > 0 && (
            <button
              type="button"
              className="icon-button"
              aria-label="Check for new episodes"
              disabled={refresh.checking}
              onClick={() => void refresh.refresh()}
            >
              <RefreshIcon />
            </button>
          )}
          <button type="button" className="icon-button" aria-label="Follow a show" onClick={() => setFollowOpen(true)}>
            <PlusIcon />
          </button>
        </div>
      </header>
      {rows.length > 0 && <RefreshNotes />}
      {data.ready && rows.length === 0 ? (
        <div className="empty">
          <p>Follow a podcast or a Substack, and its newest episodes show up here and in your Library.</p>
          <button type="button" className="button button-primary" onClick={() => setFollowOpen(true)}>
            Follow a show
          </button>
          <QuickAdd />
        </div>
      ) : (
        <ul className="rows" aria-label="Shows you follow, newest episode first">
          {rows.map((row) => (
            <li key={row.show.id} className="row show-row">
              <button
                type="button"
                className="row-open"
                data-show-id={row.show.id}
                onClick={() => setOpenShowId(row.show.id)}
                aria-label={[
                  `Open ${row.show.title}`,
                  row.newCount > 0 ? `${row.newCount} new` : '',
                  row.newest ? `latest ${shortDate(row.newest.publishedAt)}: ${row.newest.title}` : 'no episodes yet',
                ]
                  .filter(Boolean)
                  .join(', ')}
              >
                <Artwork show={row.show} />
                <span className="row-main">
                  <span className="row-title">{row.show.title}</span>
                  {row.newest && <span className="row-sub">{row.newest.title}</span>}
                  <span className="row-meta">
                    {row.newCount > 0 && <span className="tag tag-outline">{row.newCount} new</span>}
                    {row.newest ? `Latest ${shortDate(row.newest.publishedAt)}` : 'No episodes yet'}
                  </span>
                </span>
                <span className="row-chevron" aria-hidden="true">
                  <ChevronIcon />
                </span>
              </button>
              {row.newest && (
                <button
                  type="button"
                  className="icon-button play-newest"
                  aria-label={`Play the newest episode of ${row.show.title}: ${row.newest.title}`}
                  onClick={() => {
                    if (row.newest) void player.open(row.newest.id);
                    onPlay();
                  }}
                >
                  <PlayIcon size={20} />
                </button>
              )}
            </li>
          ))}
        </ul>
      )}
      {followOpen && <FollowSheet onClose={() => setFollowOpen(false)} />}
    </div>
  );
}

/** When the shows were last checked, and the one line about shows that need the server. */
function RefreshNotes() {
  const refresh = useFeedRefresh();
  // "Checked 3 minutes ago" moves on while the tab is open.
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 30_000);
    return () => window.clearInterval(timer);
  }, []);
  return (
    <div className="refresh-notes" style={{ display: 'grid', gap: 8, paddingBottom: 12 }}>
      <p className="muted" role="status" data-testid="refresh-status">
        {refresh.checking ? 'Checking for new episodes…' : checkedLabel(refresh.lastCheckedAt, now)}
      </p>
      {refresh.needsRelay > 0 && (
        <p className="problem" data-testid="refresh-needs-relay" style={{ alignItems: 'center', flexWrap: 'wrap' }}>
          <span className="toast-mark" aria-hidden="true">i</span>
          <span style={{ flex: '1 1 14em' }}>
            {refresh.relayAvailable
              ? needsRelayLine(refresh.needsRelay)
              : `${needsRelayLine(refresh.needsRelay).replace(/\.$/, '')}, and this copy of the app has no server to use.`}
          </span>
          {refresh.relayAvailable && (
            <button type="button" className="button" disabled={refresh.checking} onClick={() => void refresh.allowRelay()}>
              Use the server
            </button>
          )}
        </p>
      )}
    </div>
  );
}

function Artwork({ show }: { show: Show }) {
  const [broken, setBroken] = useState(false);
  if (!show.artworkUrl || broken) {
    return (
      <span className="artwork artwork-letter" aria-hidden="true">
        {show.title.trim().charAt(0).toUpperCase() || '?'}
      </span>
    );
  }
  return <img className="artwork" src={show.artworkUrl} alt="" loading="lazy" onError={() => setBroken(true)} />;
}

function ShowScreen({ show, onBack, onPlay }: { show: Show; onBack: () => void; onPlay: () => void }) {
  const data = useData();
  const player = usePlayer();
  const { toast } = useUi();
  const rows = libraryRows(data.episodes.filter((e) => e.showId === show.id), data.shows, data.positions);
  const heading = useRef<HTMLHeadingElement>(null);
  useEffect(() => heading.current?.focus(), []);
  return (
    <div className="screen">
      <header className="screen-header screen-header-sub">
        <button type="button" className="back-button" onClick={onBack}>
          <span className="flip" aria-hidden="true">
            <ChevronIcon />
          </span>
          Following
        </button>
      </header>
      <div className="show-head">
        <Artwork show={show} />
        <div>
          <h1 id="show-title" ref={heading} tabIndex={-1}>
            {show.title}
          </h1>
          {show.author && <p className="muted">{show.author}</p>}
          <p className="muted">Following since {shortDate(show.followedAt)}</p>
        </div>
      </div>
      <div className="show-actions">
        <button
          type="button"
          className="button"
          onClick={() => {
            void data.unfollow(show.id).then(
              () => toast(`Unfollowed ${show.title}. Its Margins stay in the Margins tab.`),
              () => undefined, // Already shown: the show is still followed, and the problem says why.
            );
            onBack();
          }}
        >
          Unfollow
        </button>
      </div>
      <ul className="rows" aria-label={`Episodes of ${show.title}`}>
        {rows.map((row) => (
          <li key={row.episode.id}>
            <button
              type="button"
              className="row episode-row"
              onClick={() => {
                void player.open(row.episode.id);
                onPlay();
              }}
            >
              <span className="row-play" aria-hidden="true">
                <PlayIcon size={20} />
              </span>
              <span className="row-main">
                <span className="row-title">{row.episode.title}</span>
                <span className="row-meta">
                  <StateTag row={row} />
                  {[shortDate(row.episode.publishedAt), minutes(row.episode.durationSeconds)].filter(Boolean).join(', ')}
                </span>
              </span>
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}

/**
 * Reads a feed and follows it (the Follow sheet's address, a search result, a suggested show). A feed the browser
 * can't read asks once for the server, through `useRelay`. `onFollowed` runs after the show is in the Library.
 */
function useFollowFeed(onFollowed?: () => void) {
  const data = useData();
  const relay = useRelay();
  const { toast } = useUi();
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<string>();

  const followFeed = useCallback(
    async (feedUrl: string) => {
      setBusy(true);
      setProblem(undefined);
      try {
        const read = await relay((relayAllowed) => services.sources.readFeed(feedUrl, { relayAllowed }));
        // Just read, so the next automatic refresh leaves it for 30 minutes.
        await data.follow({ ...read.show, refreshedAt: new Date().toISOString() }, newestFirst(read.episodes));
        toast(`Following ${read.show.title}. ${read.episodes.length} episodes added to your Library.`);
        onFollowed?.();
      } catch (error) {
        setProblem(plainError(error));
      } finally {
        setBusy(false);
      }
    },
    [data, relay, toast, onFollowed],
  );
  return { busy, problem, setProblem, followFeed };
}

function ProblemLine({ problem }: { problem: string }) {
  return (
    <p className="problem" role="alert">
      <span className="toast-mark" aria-hidden="true">!</span>
      {problem}
    </p>
  );
}

/** The suggested shows on the empty Following screen (#3610), with the way a failed follow is told. */
function QuickAdd() {
  const data = useData();
  const { busy, problem, followFeed } = useFollowFeed();
  return (
    <>
      <SuggestedShows busy={busy} followedFeedUrls={data.shows.map((s) => s.feedUrl)} onFollow={(feedUrl) => void followFeed(feedUrl)} />
      {problem && <ProblemLine problem={problem} />}
    </>
  );
}

/**
 * A short hand-picked list, one tap each (#3610). It draws letters, never artwork, and touches no feed until a tap,
 * so showing it contacts no publisher. Substack feeds can't be read by a browser directly, so the first tap
 * usually asks once about our server; the line says so before the listener taps. The button says Add, not Follow,
 * so it never shares a name with the sheet's own Follow button.
 */
function SuggestedShows({ busy, followedFeedUrls, onFollow }: { busy: boolean; followedFeedUrls: string[]; onFollow: (feedUrl: string) => void }) {
  const shows = suggestionsToShow(followedFeedUrls);
  if (shows.length === 0) return null;
  return (
    <section className="suggested" aria-labelledby="suggested-title">
      <h2 id="suggested-title">Or start with one of these</h2>
      <ul className="rows" aria-label="Suggested shows">
        {shows.map((show) => (
          <li key={show.feedUrl} className="row show-row">
            <span className="row-open">
              <span className="artwork artwork-letter" aria-hidden="true">
                {show.title.trim().charAt(0).toUpperCase()}
              </span>
              <span className="row-main">
                <span className="row-title">{show.title}</span>
                <span className="row-meta">{show.about}</span>
              </span>
            </span>
            <button type="button" className="button" disabled={busy} aria-label={`Add ${show.title}`} onClick={() => onFollow(show.feedUrl)}>
              Add
            </button>
          </li>
        ))}
      </ul>
      <p className="muted">
        These shows’ feeds can’t be read straight from a browser, so your first tap may ask to use our server. It keeps nothing.
      </p>
    </section>
  );
}

function looksLikeUrl(text: string): boolean {
  return /^https?:\/\//i.test(text) || /^[\w-]+(\.[\w-]+)+\/?\S*$/.test(text);
}

function FollowSheet({ onClose }: { onClose: () => void }) {
  const data = useData();
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<Show[]>();
  const [searching, setSearching] = useState(false);
  const { busy: following, problem, setProblem, followFeed } = useFollowFeed(onClose);
  const busy = following || searching;
  const dialog = useRef<HTMLDialogElement>(null);
  useRestoreFocus('#following-title');

  useEffect(() => {
    const d = dialog.current;
    if (d && !d.open) d.showModal();
  }, []);

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    const text = query.trim();
    if (!text) return;
    if (looksLikeUrl(text)) {
      await followFeed(/^https?:\/\//i.test(text) ? text : `https://${text}`);
      return;
    }
    setSearching(true);
    setProblem(undefined);
    try {
      const found = await services.sources.searchPodcasts(text);
      setResults(found);
      if (found.length === 0) setProblem(`No shows found for “${text}”. Try another name, or paste the show’s feed address.`);
    } catch (error) {
      setProblem(plainError(error));
    } finally {
      setSearching(false);
    }
  };

  const followed = new Set(data.shows.map((s) => s.feedUrl));
  return (
    <dialog ref={dialog} className="sheet" aria-labelledby="follow-title" onCancel={onClose}>
      <header className="sheet-header">
        <h2 id="follow-title">Follow a show</h2>
        <button type="button" className="icon-button" aria-label="Close" onClick={onClose}>
          <CloseIcon />
        </button>
      </header>
      <form className="follow-form" onSubmit={(event) => void submit(event)}>
        <label htmlFor="follow-query">Show name, or a feed or Substack address</label>
        <div className="follow-input">
          <input
            id="follow-query"
            type="search"
            inputMode="search"
            autoComplete="off"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder="Hard Fork, or name.substack.com/feed"
          />
          <button type="submit" className="button button-primary" disabled={busy}>
            {busy ? 'Looking…' : looksLikeUrl(query.trim()) ? 'Follow' : 'Search'}
          </button>
        </div>
      </form>
      {problem && <ProblemLine problem={problem} />}
      {!results?.length && (
        <SuggestedShows busy={busy} followedFeedUrls={data.shows.map((s) => s.feedUrl)} onFollow={(feedUrl) => void followFeed(feedUrl)} />
      )}
      {results && results.length > 0 && (
        <ul className="rows" aria-label="Search results">
          {results.map((show) => (
            <li key={show.feedUrl} className="row show-row">
              <span className="row-open">
                <Artwork show={show} />
                <span className="row-main">
                  <span className="row-title">{show.title}</span>
                  {show.author && <span className="row-meta">{show.author}</span>}
                </span>
              </span>
              {followed.has(show.feedUrl) ? (
                <span className="tag tag-quiet">Following</span>
              ) : (
                <button type="button" className="button" disabled={busy} onClick={() => void followFeed(show.feedUrl)}>
                  Follow
                </button>
              )}
            </li>
          ))}
        </ul>
      )}
    </dialog>
  );
}
