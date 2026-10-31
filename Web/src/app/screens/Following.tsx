import { useEffect, useRef, useState, type FormEvent } from 'react';
import type { Show } from '../../shared/model.ts';
import { useData } from '../data.tsx';
import { minutes, shortDate } from '../format.ts';
import { ChevronIcon, CloseIcon, PlayIcon, PlusIcon } from '../icons.tsx';
import { followingRows, libraryRows, newestFirst } from '../logic/library.ts';
import { plainError } from '../logic/messages.ts';
import { usePlayer } from '../player.tsx';
import { services } from '../services.ts';
import { useRelay, useUi } from '../ui.tsx';

export function Following({ onPlay, followOpen, setFollowOpen }: { onPlay: () => void; followOpen: boolean; setFollowOpen: (open: boolean) => void }) {
  const data = useData();
  const player = usePlayer();
  const [openShowId, setOpenShowId] = useState<string>();
  const rows = followingRows(data.shows, data.episodes, data.positions);
  const openShow = data.shows.find((s) => s.id === openShowId);

  if (openShow) return <ShowScreen show={openShow} onBack={() => setOpenShowId(undefined)} onPlay={onPlay} />;

  return (
    <section className="screen" aria-labelledby="following-title">
      <header className="screen-header">
        <h1 id="following-title">Following</h1>
        <button type="button" className="icon-button" aria-label="Follow a show" onClick={() => setFollowOpen(true)}>
          <PlusIcon />
        </button>
      </header>
      {data.ready && rows.length === 0 ? (
        <div className="empty">
          <p>Follow a podcast or a Substack, and its newest episodes show up here and in your Library.</p>
          <button type="button" className="button button-primary" onClick={() => setFollowOpen(true)}>
            Follow a show
          </button>
        </div>
      ) : (
        <ul className="rows" aria-label="Shows you follow, newest episode first">
          {rows.map((row) => (
            <li key={row.show.id} className="row show-row">
              <button type="button" className="row-open" onClick={() => setOpenShowId(row.show.id)} aria-label={`Open ${row.show.title}`}>
                <Artwork show={row.show} />
                <span className="row-main">
                  <span className="row-title">{row.show.title}</span>
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
    </section>
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
  return (
    <section className="screen" aria-labelledby="show-title">
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
          <h1 id="show-title">{show.title}</h1>
          {show.author && <p className="muted">{show.author}</p>}
          <p className="muted">Following since {shortDate(show.followedAt)}</p>
        </div>
      </div>
      <div className="show-actions">
        <button
          type="button"
          className="button"
          onClick={() => {
            void data.unfollow(show.id).then(() => toast(`Unfollowed ${show.title}. Its Margins stay in the Margins tab.`));
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
                <span className="row-meta">{[shortDate(row.episode.publishedAt), minutes(row.episode.durationSeconds)].filter(Boolean).join(', ')}</span>
              </span>
            </button>
          </li>
        ))}
      </ul>
    </section>
  );
}

function looksLikeUrl(text: string): boolean {
  return /^https?:\/\//i.test(text) || /^[\w-]+(\.[\w-]+)+\/?\S*$/.test(text);
}

function FollowSheet({ onClose }: { onClose: () => void }) {
  const data = useData();
  const relay = useRelay();
  const { toast } = useUi();
  const [query, setQuery] = useState('');
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<string>();
  const [results, setResults] = useState<Show[]>();
  const dialog = useRef<HTMLDialogElement>(null);

  useEffect(() => {
    const d = dialog.current;
    if (d && !d.open) d.showModal();
  }, []);

  const followFeed = async (feedUrl: string) => {
    setBusy(true);
    setProblem(undefined);
    try {
      const read = await relay((relayAllowed) => services.sources.readFeed(feedUrl, { relayAllowed }));
      await data.follow(read.show, newestFirst(read.episodes));
      toast(`Following ${read.show.title}. ${read.episodes.length} episodes added to your Library.`);
      onClose();
    } catch (error) {
      setProblem(plainError(error));
    } finally {
      setBusy(false);
    }
  };

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    const text = query.trim();
    if (!text) return;
    if (looksLikeUrl(text)) {
      await followFeed(/^https?:\/\//i.test(text) ? text : `https://${text}`);
      return;
    }
    setBusy(true);
    setProblem(undefined);
    try {
      const found = await services.sources.searchPodcasts(text);
      setResults(found);
      if (found.length === 0) setProblem(`No shows found for “${text}”. Try another name, or paste the show’s feed address.`);
    } catch (error) {
      setProblem(plainError(error));
    } finally {
      setBusy(false);
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
      {problem && (
        <p className="problem" role="alert">
          <span className="toast-mark" aria-hidden="true">!</span>
          {problem}
        </p>
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
