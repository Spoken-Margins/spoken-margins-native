import { useEffect, useMemo } from 'react';
import { formatClock } from '../../shared/clock.ts';
import { useData } from '../data.tsx';
import { minutes, shortDate } from '../format.ts';
import { PauseIcon, PlayIcon } from '../icons.tsx';
import { useMarginFilePicker, type OpenMarginFile } from '../import.tsx';
import { libraryVoiceTag } from '../logic/episode-voice-words.ts';
import { episodeVoice } from '../logic/playability.ts';
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
    () => libraryRows(libraryEpisodes(data.episodes, data.library, data.migrated), data.shows, data.positions),
    [data.episodes, data.library, data.migrated, data.shows, data.positions],
  );
  const authors = useMemo(() => marginAuthors(data.margins), [data.margins]);
  const rows = useMemo(() => allRows.filter((row) => libraryRowMatches(query, row, authors)), [allRows, authors, query]);
  // What the one-time move left on Following that the listener hasn't since added, played or removed (#4425).
  const movedOutCount = data.migrated ? stillMovedOut(data.settings.libraryMovedOut, data.episodes, data.library).length : 0;
  // A query ends when the Library empties, so rows that come back aren't hidden by an old one.
  useEffect(() => {
    if (data.ready && allRows.length === 0 && query.trim() !== '') setQuery('');
  }, [data.ready, allRows.length, query, setQuery]);

  return (
    <div className="screen">
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
            <li key={row.episode.id}>
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
            </li>
            );
          })}
          </ul>
        </>
      )}
    </div>
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
