import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent, type ReactNode } from 'react';
import { useRestoreFocus } from '../focus.ts';
import type { Episode, Show } from '../../shared/model.ts';
import { useData } from '../data.tsx';
import { minutes, shortDate } from '../format.ts';
import { ChevronIcon, CloseIcon, MoreIcon, PlayIcon, PlusIcon, RefreshIcon } from '../icons.tsx';
import { followedShows, isFollowed, onShowList, unfollowToast } from '../logic/follow-state.ts';
import { followingMatches, followingRows, libraryRows, newestFirst, type LibraryRow } from '../logic/library.ts';
import { inLibrary, libraryCountForShow, SHARED_SHOW_PREFIX } from '../logic/library-membership.ts';
import { plainError } from '../logic/messages.ts';
import { checkedLabel, needsRelayLine } from '../logic/refresh.ts';
import { normalizeFeedUrl, suggestionsToShow } from '../logic/suggestions.ts';
import { usePlayer } from '../player.tsx';
import { useFeedRefresh } from '../refresh.tsx';
import { services } from '../services.ts';
import { followingMatchLine, lookToFollowLabel, noMatchLine, SEARCH_LABELS } from '../logic/search-words.ts';
import { SearchField, SearchStatus, useClearSearches, useTabSearch } from '../search.tsx';
import { useRelay, useUi } from '../ui.tsx';
import { StateTag } from './Library.tsx';

export function Following({
  onPlay,
  followOpen,
  setFollowOpen,
  followQuery,
  onLookFor,
}: {
  onPlay: () => void;
  followOpen: boolean;
  setFollowOpen: (open: boolean) => void;
  /** What the Follow sheet opens with, when it was opened from a search that found nothing. */
  followQuery?: string;
  onLookFor: (query: string) => void;
}) {
  const data = useData();
  const player = usePlayer();
  const [openShowId, setOpenShowId] = useState<string>();
  // The show the listener came back from, so focus lands on its row again, not at the top of the page.
  const [returnTo, setReturnTo] = useState<string>();
  const refresh = useFeedRefresh();
  const { query, setQuery } = useTabSearch('following');
  // Only followed shows (#4426): an unfollowed record stays stored but leaves Following.
  const followed = useMemo(() => followedShows(data.shows), [data.shows]);
  // A dismissed episode leaves its show's row and "N new", unless it is in the Library (#4426).
  const listed = useCallback((episode: Episode) => onShowList(episode, data.dismissed, (id) => inLibrary(id, data.library)), [data.dismissed, data.library]);
  // Rebuilt only when the stored shows change, not on every keystroke.
  const rows = useMemo(() => followingRows(followed, data.episodes, data.positions, listed), [followed, data.episodes, data.positions, listed]);
  const matches = useMemo(() => followingMatches(query, rows), [query, rows]);
  const searching = query.trim() !== '';
  const episodeRows = useMemo(() => libraryRows(matches.episodes, data.shows, data.positions), [matches.episodes, data.shows, data.positions]);
  const openShow = followed.find((s) => s.id === openShowId);

  useEffect(() => {
    if (openShowId || !returnTo) return;
    const row = document.querySelector<HTMLElement>(`[data-show-id="${CSS.escape(returnTo)}"]`);
    (row ?? document.getElementById('following-title'))?.focus();
    setReturnTo(undefined);
  }, [openShowId, returnTo]);

  // A query ends when the list empties, so shows that come back aren't hidden by an old one. Above the early return, so hooks keep their order.
  useEffect(() => {
    if (data.ready && rows.length === 0 && query.trim() !== '') setQuery('');
  }, [data.ready, rows.length, query, setQuery]);

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

  const showRow = (row: (typeof rows)[number]) => (
    <li key={row.show.id} className="row show-row">
      <button
        type="button"
        className="row-open"
        data-show-id={row.show.id}
        onClick={() => setOpenShowId(row.show.id)}
        aria-label={[
          `Open ${row.show.title}`,
          row.newCount > 0 ? `${row.newCount} new` : '',
          row.newest ? `latest ${shortDate(row.newest.publishedAt)}: ${row.newest.title}` : row.dismissedCount > 0 ? 'every episode dismissed' : 'no episodes yet',
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
            {row.newest ? `Latest ${shortDate(row.newest.publishedAt)}` : row.dismissedCount > 0 ? 'Every episode dismissed' : 'No episodes yet'}
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
          aria-label={`Play the newest episode of ${row.show.title} that can play`}
          onClick={() => {
            void player.openNewestPlayable(row.episodes);
            onPlay();
          }}
        >
          <PlayIcon size={20} />
        </button>
      )}
    </li>
  );

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
      {rows.length > 0 && <SearchField label={SEARCH_LABELS.following} value={query} onChange={setQuery} />}
      {rows.length > 0 && <RefreshNotes />}
      {rows.length > 0 && (
        <SearchStatus
          query={query}
          matchLine={matches.shows.length + matches.episodes.length > 0 ? followingMatchLine(matches.shows.length, matches.episodes.length) : undefined}
          noMatchLine={noMatchLine('following', query)}
        />
      )}
      {data.ready && rows.length === 0 ? (
        <div className="empty">
          <p>Follow a podcast or a Substack. Its newest episodes show up here, and you choose which ones go in your Library.</p>
          <button type="button" className="button button-primary" onClick={() => setFollowOpen(true)}>
            Follow a show
          </button>
          {!followOpen && <QuickAdd />}
        </div>
      ) : searching && matches.shows.length + matches.episodes.length === 0 ? (
        <div className="empty">
          <button type="button" className="button look-for" onClick={() => onLookFor(query.trim())}>
            {lookToFollowLabel(query)}
          </button>
        </div>
      ) : searching ? (
        <>
          {matches.shows.length > 0 && (
            <>
              <h2 className="section-heading">Shows</h2>
              <ul className="rows" aria-label="Shows that match">
                {matches.shows.map(showRow)}
              </ul>
            </>
          )}
          {episodeRows.length > 0 && (
            <>
              <h2 className="section-heading">Episodes</h2>
              <ul className="rows" aria-label="Episodes that match, newest first">
                {episodeRows.map((row) => (
                  <FeedEpisodeRow
                    key={row.episode.id}
                    row={row}
                    kicker={row.show?.title}
                    onPlay={() => {
                      void player.open(row.episode.id);
                      onPlay();
                    }}
                  />
                ))}
              </ul>
            </>
          )}
        </>
      ) : (
        <ul className="rows" aria-label="Shows you follow, newest episode first">
          {rows.map(showRow)}
        </ul>
      )}
      {followOpen && <FollowSheet onClose={() => setFollowOpen(false)} initialQuery={followQuery} />}
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
  const heading = useRef<HTMLHeadingElement>(null);
  useEffect(() => heading.current?.focus(), []);
  const [unfollowing, setUnfollowing] = useState(false);
  const [dismissing, setDismissing] = useState<LibraryRow>();
  const [dismissedOpen, setDismissedOpen] = useState(false);
  // Each row's ⋯ by episode id, and the Dismissed episodes button: focus moves between them after a dismissal (#4426).
  const moreButtons = useRef(new Map<string, HTMLButtonElement>());
  const dismissedToggle = useRef<HTMLButtonElement>(null);
  // Focus to move once the change has been drawn.
  const afterRender = useRef<(() => void) | undefined>(undefined);
  useEffect(() => {
    const move = afterRender.current;
    if (!move) return;
    afterRender.current = undefined;
    requestAnimationFrame(move);
  });

  const all = libraryRows(data.episodes.filter((e) => e.showId === show.id), data.shows, data.positions);
  const inLib = (id: string) => inLibrary(id, data.library);
  const rows = all.filter((row) => onShowList(row.episode, data.dismissed, inLib));
  const dismissedRows = data.migrated ? all.filter((row) => !onShowList(row.episode, data.dismissed, inLib)) : [];
  const listId = `dismissed-${show.id.replace(/[^A-Za-z0-9_-]/g, '_')}`;

  const play = (row: LibraryRow) => {
    void player.open(row.episode.id);
    onPlay();
  };
  const focusMore = (id: string) => () => moreButtons.current.get(id)?.focus();

  const unfollow = async () => {
    if (unfollowing) return;
    setUnfollowing(true);
    // Counted before the write, from what is stored now.
    const toastLine = unfollowToast({
      title: show.title,
      shared: show.id.startsWith(SHARED_SHOW_PREFIX),
      migrated: data.migrated,
      inLibrary: libraryCountForShow(show.id, data.episodes, data.library, true),
      leaving: libraryCountForShow(show.id, data.episodes, data.library, false),
      hasMargins: data.margins.some((m) => all.some((row) => row.episode.id === m.episodeId)),
    });
    try {
      await data.unfollowShow(show.id);
    } catch {
      setUnfollowing(false); // Already shown: the show is still followed, and the problem says why.
      return;
    }
    // The row is already gone from this render, so focus falls back to the Following heading.
    onBack();
    const showId = show.id;
    const title = show.title;
    toast(toastLine, 'info', {
      label: 'Undo',
      run: () =>
        data.undoUnfollow(showId).then(
          () => {
            toast(`Following ${title} again.`);
            requestAnimationFrame(() => document.querySelector<HTMLElement>(`[data-show-id="${CSS.escape(showId)}"]`)?.focus());
          },
          () => undefined, // Already shown; the show can still be followed from the Follow sheet.
        ),
    });
  };

  const dismiss = async (row: LibraryRow) => {
    const id = row.episode.id;
    const title = row.episode.title;
    const order = rows.map((r) => r.episode.id);
    let previous;
    try {
      previous = await data.dismissEpisode(id);
    } catch {
      setDismissing(undefined); // Already shown; the row stays.
      afterRender.current = focusMore(id);
      return;
    }
    setDismissing(undefined);
    afterRender.current = () => {
      const at = order.indexOf(id);
      const target =
        order.slice(at + 1).map((other) => moreButtons.current.get(other)).find(Boolean) ??
        order.slice(0, at).reverse().map((other) => moreButtons.current.get(other)).find(Boolean) ??
        dismissedToggle.current ??
        document.getElementById('show-title');
      target?.focus();
    };
    toast(`Dismissed “${title}”.`, 'info', {
      label: 'Undo',
      run: () =>
        data.undoDismiss(id, previous).then(
          () => {
            toast(`“${title}” is back in the list.`);
            requestAnimationFrame(focusMore(id));
          },
          () => undefined, // Already shown; it can still be brought back from Dismissed episodes.
        ),
    });
  };

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
        <button type="button" className="button" disabled={unfollowing} onClick={() => void unfollow()}>
          Unfollow
        </button>
      </div>
      {rows.length === 0 && dismissedRows.length > 0 ? (
        <p className="muted">You’ve dismissed every episode here.</p>
      ) : (
        <ul className="rows" aria-label={`Episodes of ${show.title}`}>
          {rows.map((row) => (
            <FeedEpisodeRow
              key={row.episode.id}
              row={row}
              onPlay={() => play(row)}
              onMore={data.migrated && !inLib(row.episode.id) ? () => setDismissing(row) : undefined}
              moreRef={(el) => {
                if (el) moreButtons.current.set(row.episode.id, el);
                else moreButtons.current.delete(row.episode.id);
              }}
            />
          ))}
        </ul>
      )}
      {dismissedRows.length > 0 && (
        <>
          <button
            ref={dismissedToggle}
            type="button"
            className="dismissed-toggle"
            aria-expanded={dismissedOpen}
            aria-controls={listId}
            onClick={() => setDismissedOpen((open) => !open)}
          >
            <span>Dismissed episodes ({dismissedRows.length})</span>
            <span className={`margin-group-chevron${dismissedOpen ? ' is-open' : ''}`} aria-hidden="true">
              <ChevronIcon />
            </span>
          </button>
          {dismissedOpen && (
            <ul id={listId} className="rows" aria-label={`Dismissed episodes of ${show.title}`}>
              {dismissedRows.map((row) => (
                <FeedEpisodeRow
                  key={row.episode.id}
                  row={row}
                  onPlay={() => play(row)}
                  trailing={
                    <BringBack
                      episodeId={row.episode.id}
                      title={row.episode.title}
                      onBack={() => {
                        afterRender.current = () => (dismissedToggle.current ?? moreButtons.current.get(row.episode.id))?.focus();
                      }}
                    />
                  }
                />
              ))}
            </ul>
          )}
        </>
      )}
      {dismissing && (
        <DismissSheet
          row={dismissing}
          onDismiss={() => dismiss(dismissing)}
          onCancel={() => {
            const id = dismissing.episode.id;
            setDismissing(undefined);
            afterRender.current = focusMore(id);
          }}
        />
      )}
    </div>
  );
}

/** A dismissed episode's Bring back (#4426): puts it back in its show's list. */
function BringBack({ episodeId, title, onBack }: { episodeId: string; title: string; onBack: () => void }) {
  const data = useData();
  const { toast } = useUi();
  const [writing, setWriting] = useState(false);
  return (
    <button
      type="button"
      className="button library-add"
      aria-label={`Bring back ${title}`}
      disabled={writing}
      onClick={() => {
        setWriting(true);
        data.bringBack(episodeId).then(
          () => {
            onBack();
            toast(`“${title}” is back in the list.`);
          },
          () => setWriting(false), // Already shown; the row stays.
        );
      }}
    >
      Bring back
    </button>
  );
}

/**
 * Dismiss asks nothing more than this (Undo covers a slip, #4426). Escape and Cancel close it with no change. While the
 * write runs, Dismiss is disabled and the sheet stays open. The show screen moves focus itself when it closes.
 */
function DismissSheet({ row, onDismiss, onCancel }: { row: LibraryRow; onDismiss: () => Promise<void>; onCancel: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const first = useRef<HTMLButtonElement>(null);
  const [writing, setWriting] = useState(false);
  useEffect(() => {
    const d = dialog.current;
    if (d && !d.open) d.showModal();
    first.current?.focus();
  }, []);
  return (
    <dialog
      ref={dialog}
      className="sheet"
      aria-labelledby="dismiss-title"
      onCancel={(event) => {
        event.preventDefault();
        if (!writing) onCancel();
      }}
    >
      <h2 id="dismiss-title" className="remove-sheet-title">
        {row.episode.title}
      </h2>
      <p className="muted">It leaves this list and the new count. Nothing is deleted.</p>
      <div className="remove-sheet-actions">
        <button
          ref={first}
          type="button"
          className="button button-primary"
          disabled={writing}
          onClick={() => {
            setWriting(true);
            void onDismiss();
          }}
        >
          Dismiss
        </button>
        <button type="button" className="button" disabled={writing} onClick={onCancel}>
          Cancel
        </button>
      </div>
    </dialog>
  );
}

/**
 * One stored episode of a followed show: play it, and, once the store is migrated, Add it to the Library (#4425). The
 * show screen and the Episodes section of a Following search draw it alike; `kicker` is the show's title in the latter.
 * It has no current-episode state, as the show screen's rows never had.
 */
function FeedEpisodeRow({
  row,
  onPlay,
  kicker,
  onMore,
  moreRef,
  trailing,
}: {
  row: LibraryRow;
  onPlay: () => void;
  kicker?: string;
  /** The ⋯ that opens Dismiss (#4426), on a show screen row not in the Library. */
  onMore?: () => void;
  moreRef?: (el: HTMLButtonElement | null) => void;
  /** Drawn instead of Add (the Dismissed episodes list's Bring back). */
  trailing?: ReactNode;
}) {
  const data = useData();
  return (
    <li className={data.migrated ? 'show-episode' : undefined}>
      <button type="button" className="row episode-row" onClick={onPlay}>
        <span className="row-play" aria-hidden="true">
          <PlayIcon size={20} />
        </span>
        <span className="row-main">
          {kicker && <span className="row-kicker">{kicker}</span>}
          <span className="row-title">{row.episode.title}</span>
          <span className="row-meta">
            <StateTag row={row} />
            {[shortDate(row.episode.publishedAt), minutes(row.episode.durationSeconds)].filter(Boolean).join(', ')}
          </span>
        </span>
      </button>
      {trailing ?? (data.migrated && <LibraryControl episodeId={row.episode.id} title={row.episode.title} />)}
      {onMore && (
        <button type="button" className="icon-button" aria-label={`More for ${row.episode.title}`} aria-haspopup="dialog" ref={moreRef} onClick={onMore}>
          <MoreIcon />
        </button>
      )}
    </li>
  );
}

/** The show screen's Add, or the words "In Library" once the episode is in (#4425). Only drawn once the store is migrated. */
function LibraryControl({ episodeId, title }: { episodeId: string; title: string }) {
  const data = useData();
  const { toast } = useUi();
  const [writing, setWriting] = useState(false);
  if (inLibrary(episodeId, data.library)) return <span className="library-state muted">In Library</span>;
  return (
    <button
      type="button"
      className="button library-add"
      aria-label={`Add ${title} to your Library`}
      disabled={writing}
      onClick={() => {
        setWriting(true);
        data.addToLibrary(episodeId).then(
          () => toast(`Added “${title}” to your Library.`),
          () => setWriting(false), // Already shown, and the button goes back to Add.
        );
      }}
    >
      Add
    </button>
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
  const clearSearches = useClearSearches();
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<string>();

  const followFeed = useCallback(
    async (feedUrl: string) => {
      setBusy(true);
      setProblem(undefined);
      try {
        const read = await relay((relayAllowed) => services.sources.readFeed(feedUrl, { relayAllowed }), { link: feedUrl });
        // Just read, so the next automatic refresh leaves it for 30 minutes.
        await data.follow({ ...read.show, refreshedAt: new Date().toISOString() }, newestFirst(read.episodes));
        toast(`Following ${read.show.title}. Open it to pick episodes for your Library.`);
        // A followed show must not sit behind a search kept from before. Not through `onFollowed`, which also runs on Close.
        clearSearches();
        onFollowed?.();
      } catch (error) {
        setProblem(plainError(error));
      } finally {
        setBusy(false);
      }
    },
    [data, relay, toast, onFollowed, clearSearches],
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
  // The empty screen is replaced by the list of shows, taking the tapped button with it, so focus goes to the heading.
  const { busy, problem, followFeed } = useFollowFeed(() => document.getElementById('following-title')?.focus());
  return (
    <>
      {problem && <ProblemLine problem={problem} />}
      <SuggestedShows busy={busy} followedFeedUrls={followedShows(data.shows).map((s) => s.feedUrl)} onFollow={(feedUrl) => void followFeed(feedUrl)} />
    </>
  );
}

/**
 * A short hand-picked list, one tap each (#3610). It draws letters, never artwork, and touches no feed until a tap,
 * so showing it contacts no publisher. Substack feeds can't be read by a browser directly, so the first tap
 * usually asks once about our server; the line says so before the listener taps. The button says Add, not Follow,
 * so it never shares a name with the sheet's own Follow button.
 */
function SuggestedShows({
  busy,
  followedFeedUrls,
  onFollow,
  inSheet = false,
}: {
  busy: boolean;
  followedFeedUrls: string[];
  onFollow: (feedUrl: string) => void;
  /** In the sheet the heading sits under the sheet's own h2. */
  inSheet?: boolean;
}) {
  const shows = suggestionsToShow(followedFeedUrls);
  if (shows.length === 0) return null;
  return (
    <section className="suggested" aria-labelledby="suggested-title">
      {inSheet ? <h3 id="suggested-title">Or start with one of these</h3> : <h2 id="suggested-title">Or start with one of these</h2>}
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

function FollowSheet({ onClose, initialQuery }: { onClose: () => void; initialQuery?: string }) {
  const data = useData();
  const [query, setQuery] = useState(initialQuery ?? '');
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

  /** The name search: what Search does, and what runs by itself when the sheet is given a name to look for. */
  const runSearch = useCallback(
    async (text: string) => {
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
    },
    [setProblem],
  );

  // Given a name, look for it at once. An address is only filled in: following stays a tap.
  const started = useRef(false);
  useEffect(() => {
    if (started.current) return;
    started.current = true;
    const text = initialQuery?.trim();
    if (text && !looksLikeUrl(text)) void runSearch(text);
  }, [initialQuery, runSearch]);

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    const text = query.trim();
    if (!text) return;
    if (looksLikeUrl(text)) {
      await followFeed(/^https?:\/\//i.test(text) ? text : `https://${text}`);
      return;
    }
    await runSearch(text);
  };

  // Only followed shows carry the tag: an unfollowed one offers Follow again (#4426, #646).
  const followedList = followedShows(data.shows);
  const followed = new Set(followedList.map((s) => normalizeFeedUrl(s.feedUrl)));
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
      {/* The app's Follow sheet footer, word for word (#4176): where a paid show's private RSS link comes from. */}
      <p className="muted" data-testid="follow-private-feed-hint">
        Or type a show’s feed link. For a paid show, such as one on Patreon, copy your private RSS link from the creator’s page.
      </p>
      {problem && <ProblemLine problem={problem} />}
      {!results?.length && (
        <SuggestedShows inSheet busy={busy} followedFeedUrls={followedList.map((s) => s.feedUrl)} onFollow={(feedUrl) => void followFeed(feedUrl)} />
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
              {followed.has(normalizeFeedUrl(show.feedUrl)) ? (
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
