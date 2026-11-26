import { useEffect, useMemo, useRef, useState } from 'react';
import { formatClock } from '../../shared/clock.ts';
import type { Show } from '../../shared/model.ts';
import { useData } from '../data.tsx';
import { useRestoreFocus } from '../focus.ts';
import { minutes, shortDate } from '../format.ts';
import { MoreIcon, PauseIcon, PlayIcon } from '../icons.tsx';
import { useMarginFilePicker, type OpenMarginFile } from '../import.tsx';
import { libraryVoiceTag } from '../logic/episode-voice-words.ts';
import { episodeVoice } from '../logic/playability.ts';
import { isFollowed } from '../logic/follow-state.ts';
import { followsAShow, libraryEpisodes, stillMovedOut } from '../logic/library-membership.ts';
import { libraryRows, libraryRowMatches, marginAuthors, type LibraryRow } from '../logic/library.ts';
import { usePlayer } from '../player.tsx';
import { useUi } from '../ui.tsx';
import { libraryMatchLine, noMatchLine, SEARCH_LABELS } from '../logic/search-words.ts';
import { SearchField, SearchStatus, useTabSearch } from '../search.tsx';

export function Library({ onPlay, onFindShows, onGoFollowing, onOpenFile }: { onPlay: () => void; onFindShows: () => void; onGoFollowing: () => void; onOpenFile: OpenMarginFile }) {
  const data = useData();
  const { toast } = useUi();
  const player = usePlayer();
  // A friend's Margin file is opened where a listener looks first (#3039, owner 2026-10-31: "I didn't see a way to
  // import margins"). The Margins tab keeps the same button.
  const picker = useMarginFilePicker(onOpenFile);
  const { query, setQuery } = useTabSearch('library');
  const allRows = useMemo(
    () => libraryRows(libraryEpisodes(data.episodes, data.library, data.migrated, data.shows), data.shows, data.positions),
    [data.episodes, data.library, data.migrated, data.shows, data.positions],
  );
  const authors = useMemo(() => marginAuthors(data.margins), [data.margins]);
  const rows = useMemo(() => allRows.filter((row) => libraryRowMatches(query, row, authors)), [allRows, authors, query]);
  // What the one-time move left on Following that the listener hasn't since added, played or removed (#4425).
  const movedOutCount = data.migrated ? stillMovedOut(data.settings.libraryMovedOut, data.episodes, data.library, data.shows).length : 0;
  // The ⋯ button of each row, by episode id: after a Remove, focus moves to a neighbour's (#4424).
  const moreButtons = useRef(new Map<string, HTMLButtonElement>());
  const screen = useRef<HTMLDivElement>(null);
  const [removing, setRemoving] = useState<LibraryRow | undefined>(undefined);
  const removeBusy = useRef(false);
  const pendingFocus = useRef<{ gone: string; order: string[] } | undefined>(undefined);

  const remove = async (row: LibraryRow) => {
    if (removeBusy.current) return;
    removeBusy.current = true;
    const id = row.episode.id;
    const title = row.episode.title;
    const order = rows.map((r) => r.episode.id);
    const hasMargins = data.margins.some((m) => m.episodeId === id);
    // Closed first, so a second tap can't write twice and the page behind is live again.
    setRemoving(undefined);
    try {
      const previous = await data.removeFromLibrary(id);
      pendingFocus.current = { gone: id, order };
      toast(removedLine(title, hasMargins, row.show), 'info', {
        label: 'Undo',
        run: () =>
          data.putBackInLibrary(id, previous).then(
            () => toast(`“${title}” is back in your Library.`),
            () => undefined, // Already shown as a problem, and the row stays out.
          ),
      });
    } catch {
      // Already shown as a problem; the row stays.
    } finally {
      removeBusy.current = false;
    }
  };

  // After a Remove: the next row's ⋯, the previous row's, the search field, then the empty state's button.
  useEffect(() => {
    const pending = pendingFocus.current;
    if (!pending || rows.some((r) => r.episode.id === pending.gone)) return;
    pendingFocus.current = undefined;
    const at = pending.order.indexOf(pending.gone);
    const live = new Set(rows.map((r) => r.episode.id));
    const next = pending.order.slice(at + 1).find((id) => live.has(id));
    const before = pending.order.slice(0, at).reverse().find((id) => live.has(id));
    requestAnimationFrame(() => {
      const target =
        (next !== undefined ? moreButtons.current.get(next) : undefined) ??
        (before !== undefined ? moreButtons.current.get(before) : undefined) ??
        screen.current?.querySelector<HTMLElement>('.search input') ??
        screen.current?.querySelector<HTMLElement>('.empty .button-primary');
      target?.focus();
    });
  }, [rows]);

  // A query ends when the Library empties, so rows that come back aren't hidden by an old one.
  useEffect(() => {
    if (data.ready && allRows.length === 0 && query.trim() !== '') setQuery('');
  }, [data.ready, allRows.length, query, setQuery]);

  return (
    <div className="screen" ref={screen}>
      <header className="screen-header">
        <h1 id="library-title" tabIndex={-1}>
          Library
        </h1>
        <div className="header-actions">
          <button type="button" className="button" onClick={picker.choose}>
            Open a Margin file
          </button>
        </div>
        {picker.input}
      </header>
      {movedOutCount > 0 && (
        <section className="library-notice" aria-label="What moved out of your Library">
          <p>
            {movedOutCount === 1
              ? 'Your Library now holds only what you add, play or get from a friend. 1 episode you hadn’t started is still on Following, under its show.'
              : `Your Library now holds only what you add, play or get from a friend. ${movedOutCount} episodes you hadn’t started are still on Following, under their shows.`}
          </p>
          <div className="library-notice-actions">
            <button
              type="button"
              className="button"
              onClick={() => {
                data.putBackMovedOut().then(
                  (n) => toast(n === 1 ? 'Put 1 episode back in your Library.' : `Put ${n} episodes back in your Library.`),
                  () => undefined, // Already shown, and the notice stays.
                );
              }}
            >
              Put them back
            </button>
            <button type="button" className="button" onClick={() => void data.dismissLibraryNotice()}>
              Got it
            </button>
          </div>
        </section>
      )}
      {allRows.length > 0 && <SearchField label={SEARCH_LABELS.library} value={query} onChange={setQuery} />}
      {data.ready && allRows.length === 0 ? (
        <div className="empty">
          {data.migrated && followsAShow(data.shows) ? (
            <>
              <p>Nothing in your Library yet. Open a show on Following and tap Add, or play an episode, and it appears here.</p>
              <button type="button" className="button button-primary" onClick={onGoFollowing}>
                Go to Following
              </button>
            </>
          ) : (
            <>
              <p>Episodes you add from the shows you follow, and the ones friends send you, appear here.</p>
              <button type="button" className="button button-primary" onClick={onFindShows}>
                Find a show to follow
              </button>
            </>
          )}
          <p>Got a .spokenmargins file from a friend? Choose Open a Margin file above. It opens at their first Margin, ready to play.</p>
        </div>
      ) : (
        <>
          {/* Always on the page, so a screen reader hears the words arrive. */}
          <SearchStatus query={query} matchLine={rows.length > 0 ? libraryMatchLine(rows.length) : undefined} noMatchLine={noMatchLine('library', query)} />
          <ul className="rows" aria-label="Episodes, newest first">
          {rows.map((row) => {
            const current = player.episode?.id === row.episode.id;
            return (
            <li key={row.episode.id} className="library-row">
              <button
                type="button"
                aria-current={current ? 'true' : undefined}
                className={`row episode-row${current ? ' is-current' : ''}`}
                onClick={() => {
                  void player.open(row.episode.id);
                  onPlay();
                }}
              >
                <span className="row-play" aria-hidden="true">
                  {current && player.playing ? <PauseIcon size={20} /> : <PlayIcon size={20} />}
                </span>
                <span className="row-main">
                  <span className="row-kicker">{row.show?.title}</span>
                  <span className="row-title">{row.episode.title}</span>
                  <span className="row-meta">
                    {current ? <span className="tag tag-status">{player.playing ? 'Playing' : 'Paused'}</span> : <StateTag row={row} />}
                    {[shortDate(row.episode.publishedAt), minutes(row.episode.durationSeconds)].filter(Boolean).join(', ')}
                  </span>
                  {row.state === 'started' && row.progress !== undefined && (
                    <span className="progress" aria-hidden="true">
                      <span style={{ width: `${row.progress * 100}%` }} />
                    </span>
                  )}
                </span>
              </button>
              {data.migrated && (
                <button
                  type="button"
                  className="icon-button"
                  aria-label={`More for ${row.episode.title}`}
                  aria-haspopup="dialog"
                  ref={(el) => {
                    if (el) moreButtons.current.set(row.episode.id, el);
                    else moreButtons.current.delete(row.episode.id);
                  }}
                  onClick={() => setRemoving(row)}
                >
                  <MoreIcon />
                </button>
              )}
            </li>
            );
          })}
          </ul>
        </>
      )}
      {removing && <RemoveSheet row={removing} onRemove={() => void remove(removing)} onClose={() => setRemoving(undefined)} />}
    </div>
  );
}

/**
 * The Remove toast. A Margin on the episode wins, since the Margins tab still reaches it; an episode of a show the
 * listener unfollowed says how to find it again (#4426), since no show screen lists it now.
 */
export function removedLine(title: string, hasMargins: boolean, show: Show | undefined): string {
  if (hasMargins) return `Removed “${title}” from your Library. Its Margins stay in the Margins tab.`;
  if (show && !isFollowed(show)) return `Removed “${title}” from your Library. Follow ${show.title} again to find it.`;
  return `Removed “${title}” from your Library.`;
}

/** Remove from Library asks nothing more than this (Undo covers a slip). Escape and Cancel close it with no change. */
function RemoveSheet({ row, onRemove, onClose }: { row: LibraryRow; onRemove: () => void; onClose: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const first = useRef<HTMLButtonElement>(null);
  useRestoreFocus('#library-title');
  useEffect(() => {
    const d = dialog.current;
    if (d && !d.open) d.showModal();
    first.current?.focus();
  }, []);
  return (
    <dialog
      ref={dialog}
      className="sheet"
      aria-labelledby="remove-title"
      onCancel={(event) => {
        event.preventDefault();
        onClose();
      }}
    >
      <h2 id="remove-title" className="remove-sheet-title">
        {row.episode.title}
      </h2>
      <div className="remove-sheet-actions">
        <button ref={first} type="button" className="button button-primary" onClick={onRemove}>
          Remove from Library
        </button>
        <button type="button" className="button" onClick={onClose}>
          Cancel
        </button>
      </div>
    </dialog>
  );
}

/** New, Resume at, Played: a word for every state, so none rests on colour. */
export function StateTag({ row }: { row: LibraryRow }) {
  if (row.state === 'started' && row.resumeAt !== undefined) {
    return <span className="tag tag-status">Resume at {formatClock(row.resumeAt)}</span>;
  }
  if (row.state === 'finished') return <span className="tag tag-quiet">Played</span>;
  const tag = libraryVoiceTag(episodeVoice(row.episode));
  return <span className={`tag tag-${tag.style}`}>{tag.text}</span>;
}
